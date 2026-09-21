"""Bounded, local read-only observations for the finite direct lifecycle.

The sealed caller verifies its source before importing this worker. No SSH,
model paths, mounts, neighbour probes, or network/service writes occur here.
Every failed query is an error, never evidence that a workload is absent.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

SERVICES = ('cluster-fabric-profile.service', 'cluster-direct-idle.service', 'ray-cluster.service')
SW = '/run/current-system/sw/bin/'
SUDO = '/run/wrappers/bin/sudo'


def require(ok, why):
    if not ok: raise RuntimeError(why)


class Query:
    def __init__(self, seconds=90):
        require(type(seconds) is int and 1 <= seconds <= 90, 'snapshot deadline')
        self.deadline = time.monotonic() + seconds

    def __call__(self, argv):
        left = self.deadline - time.monotonic()
        require(left > 0, 'snapshot deadline expired')
        p = subprocess.run(argv, cwd='/', text=True, capture_output=True, timeout=min(5, left))
        require(p.returncode == 0, 'snapshot query failed: ' + repr(argv) + ': ' + p.stderr[:2048])
        require(len(p.stdout.encode()) <= 1048576, 'snapshot output exceeds bound')
        return p.stdout


def properties(text):
    result = {}
    for line in text.splitlines():
        require('=' in line, 'malformed service property')
        name, value = line.split('=', 1)
        require(name and name not in result, 'duplicate service property')
        result[name] = value
    return result


def rows(text):
    values = json.loads(text)
    require(isinstance(values, list) and all(isinstance(v, dict) for v in values), 'IP observation schema')
    return sorted(values, key=lambda value: json.dumps(value, sort_keys=True))


def process_inventory(text, observer_pid,declared=None,read=None,resolve=None):
    """Retain full process argv and classify interpreter/transfer workloads.

    The observer and its live ancestor chain are not competing jobs. Their
    identity is retained in the raw inventory; exact controller/cgroup closure
    is a separate mandatory recovery gate, not replaced by this heuristic.
    """
    processes=[]
    for line in text.splitlines():
        fields=line.split(None,4)
        require(len(fields)==5 and all(x.isdigit() for x in fields[:3]),'complete process observation schema')
        processes.append(dict(pid=int(fields[0]),ppid=int(fields[1]),uid=int(fields[2]),name=fields[3],argv=fields[4]))
    require(len({x['pid'] for x in processes})==len(processes),'duplicate process identity')
    bypid={x['pid']:x for x in processes};ancestors=set();pid=observer_pid
    while pid in bypid and pid not in ancestors:
        ancestors.add(pid);pid=bypid[pid]['ppid']
    if declared is not None:
        require(set(declared)=={'pid','uid','startTicks','argv','executable'} and type(declared['pid'])is int and declared['pid']>0 and
                type(declared['uid'])is int and isinstance(declared['argv'],list) and declared['argv'] and
                re.fullmatch('[0-9]+',declared['startTicks']) and declared['executable'].startswith('/nix/store/'),'invalid exact foreground observer claim')
        if declared['pid'] in bypid:
            require(read is not None and resolve is not None,'observer process identity reader required')
            base='/proc/'+str(declared['pid']);entry=bypid[declared['pid']]
            require(entry['uid']==declared['uid'] and entry['argv']==' '.join(declared['argv']) and
                    read(base+'/stat').split(') ',1)[1].split()[19]==declared['startTicks'] and
                    read(base+'/cmdline').split('\0')[:-1]==declared['argv'] and resolve(base+'/exe')==declared['executable'],
                    'foreground observer PID/argv/start/executable changed')
            ancestors.add(declared['pid'])
    executable=re.compile(r'^(?:python[0-9.]*|node|ruby|java|julia|iperf[0-9]*|ib_[A-Za-z0-9_]+|all_reduce_perf|raylet|vllm.*|sglang.*|rsync|scp|sftp|curl|wget|hf|huggingface.*|rclone)$')
    argument=re.compile(r'(?:^|[/\s])(?:vllm|sglang|raylet|torchrun|nccl-tests|all_reduce_perf|ib_write_bw|ib_read_bw|huggingface-cli)(?:[/\s.]|$)')
    suspect=[x for x in processes if x['pid'] not in ancestors and (executable.fullmatch(x['name']) or argument.search(x['argv']))]
    return sorted(processes,key=lambda x:x['pid']),sorted(suspect,key=lambda x:x['pid'])


def firewall_tables(text):
    """Inventory from a complete save stream, valid for nft and legacy backends."""
    tables=[];current=None
    for row in text.splitlines():
        if not row or row.startswith('#'):continue
        if row.startswith('*'):
            name=row[1:]
            require(current is None and name in {'filter','mangle','nat','raw','security'} and name not in tables,'unknown/duplicate/unclosed firewall table')
            tables.append(name);current=name
        elif row=='COMMIT':
            require(current is not None,'firewall commit without table');current=None
        else:
            require(current is not None and (row.startswith(':') or row.startswith('-A ')),'invalid firewall save stream')
    require(current is None and 'filter' in tables,'firewall save incomplete/missing filter')
    return sorted(tables)


def fec_settings(text):
    """Parse exactly the two bounded FEC rows used by the active direct rail."""
    wanted=('Supported/Configured FEC encodings','Active FEC encoding')
    require(len(text.encode())<=4096,'FEC output exceeds bound')
    rows=[(key.strip(),value.strip()) for line in text.splitlines()
          for key,separator,value in [line.partition(':')]
          if separator and key.strip() in wanted]
    require(len(rows)==2 and [key for key,_ in rows]==list(wanted) and
            all(value and len(value)<=128 for _,value in rows),'direct FEC observation schema')
    return dict(configured=rows[0][1],active=rows[1][1])


def hca_link(text,hca,nic):
    """Select one exact RDMA port and retain its physical/network binding."""
    require(re.fullmatch('[A-Za-z0-9_]+',hca) is not None,'direct HCA identity schema')
    matches=[]
    for line in text.splitlines():
        row=line.split()
        if row[:2]!=['link',hca+'/1']:continue
        require(len(row[2:])%2==0,'malformed direct HCA record')
        values=dict(zip(row[2::2],row[3::2]));matches.append(values)
    expected={'state':'ACTIVE','physical_state':'LINK_UP','netdev':nic}
    require(len(matches)==1 and all(matches[0].get(key)==value for key,value in expected.items()),
            'direct HCA port/state/netdev mismatch')
    return dict(device=hca,port=1,state=matches[0]['state'],physicalState=matches[0]['physical_state'],netdev=matches[0]['netdev'])


def idle_unit(run,name):
    base=[SW+'systemctl','show',name,'-p','Id','-p','LoadState','-p','ActiveState','-p','SubState']
    argv=base+(['-p','MainPID'] if name.endswith('.service') else [])
    value=properties(run(argv));expected={'Id','LoadState','ActiveState','SubState'}|({'MainPID'} if name.endswith('.service') else set())
    require(set(value)==expected and value['Id']==name and
            value['LoadState'] in ('loaded','not-found') and value['ActiveState']=='inactive' and
            value['SubState']=='dead' and (not name.endswith('.service') or value['MainPID']=='0'),
            'disabled Docker unit active/unknown: '+name)
    return value


def collect(cfg, run=None, read=None, resolve=None):
    run = Query() if run is None else run
    read = (lambda path: Path(path).read_text().strip()) if read is None else read
    resolve = os.path.realpath if resolve is None else resolve
    actual = dict(hostname=run([SW+'hostname', '-s']).strip(),
                  serial=run([SUDO, '-n', SW+'cat', '/sys/class/dmi/id/product_serial']).strip(),
                  bootId=read('/proc/sys/kernel/random/boot_id'), systemClosure=resolve('/run/current-system'),
                  persistentClosure=resolve('/nix/var/nix/profiles/system'))
    for key in ('hostname', 'serial', 'bootId', 'systemClosure'):
        require(actual[key] == cfg[key], 'snapshot identity mismatch: '+key)
    predeclared=cfg.get('networkLifecycle','transient-switched')=='predeclared-direct'
    persistent=cfg.get('persistentClosure',cfg['systemClosure']) if predeclared else cfg['systemClosure']
    require(actual['persistentClosure'] == persistent, 'persistent closure changed')
    nics = [cfg['directInterface'], cfg['siblingInterface'], *cfg['switchInterfaces'], cfg['managementInterface']]
    require(len(nics) == 5 and len(set(nics)) == 5 and all(re.fullmatch('[A-Za-z0-9]+', nic) for nic in nics), 'five distinct safe interface names')
    actual['macs'] = {nic: read('/sys/class/net/'+nic+'/address') for nic in nics}
    require(actual['macs'] == cfg['macs'], 'physical MAC identity mismatch')
    actual['services'] = {}; actual['unitDefinitions'] = {}
    for name in SERVICES:
        value = properties(run([SW+'systemctl','show',name,'-p','Id','-p','LoadState','-p','ActiveState','-p','SubState','-p','MainPID','-p','FragmentPath']))
        require(set(value) == {'Id','LoadState','ActiveState','SubState','MainPID','FragmentPath'} and value['Id'] == name, 'service observation incomplete')
        require(value['LoadState'] in ('loaded','not-found'), 'unit load failure')
        actual['services'][name] = {k:value[k] for k in ('LoadState','ActiveState','SubState','MainPID')}
        if value['LoadState'] == 'loaded':
            require(value['FragmentPath'].startswith('/nix/store/') or value['FragmentPath'].startswith('/etc/systemd/'), 'unexpected profile unit source')
            unit = run([SW+'systemctl','cat',name])
            require(unit.strip(), 'empty loaded unit definition')
            actual['unitDefinitions'][name] = dict(fragmentPath=value['FragmentPath'], sha256=hashlib.sha256(unit.encode()).hexdigest())
        else:
            require(value['FragmentPath'] == '' and value['ActiveState']=='inactive' and value['SubState']=='dead' and value['MainPID']=='0', 'ambiguous missing unit')
            actual['unitDefinitions'][name] = None
    actual['workloads'] = {}
    workload_queries=[
        ('podman',[SW+'podman','ps','-aq']),
        ('rootPodman',[SUDO,'-n',SW+'podman','ps','-aq']),
        ('gpu',[SW+'nvidia-smi','--query-compute-apps=pid','--format=csv,noheader'])]
    if predeclared:
        require(type(cfg.get('dockerEnabled')) is bool,'explicit sealed Docker policy required')
        if cfg['dockerEnabled']:
            workload_queries.append(('docker',[SUDO,'-n',SW+'docker','ps','-aq']))
            actual['dockerPolicy']=dict(enabled=True,units=None)
        else:
            actual['workloads']['docker']=[]
            actual['dockerPolicy']=dict(enabled=False,units={name:idle_unit(run,name) for name in ('docker.service','docker.socket')})
    else:
        workload_queries.append(('docker',[SUDO,'-n',SW+'docker','ps','-aq']))
    for label, argv in workload_queries:
        actual['workloads'][label] = run(argv).splitlines()
    actual['processInventory'],actual['workloads']['benchmarks']=process_inventory(
        run([SW+'ps','-ww','-eo','pid=,ppid=,uid=,comm=,args=']),os.getpid(),cfg.get('frontendProcess'),read,resolve)
    if predeclared and not cfg['dockerEnabled']:
        actual['workloads']['docker']=[row for row in actual['processInventory'] if row['name']=='dockerd']
    actual['activeServiceInventory']={}
    for scope in ('system','user'):
        argv=[SW+'systemctl',*(['--user'] if scope=='user' else []),'list-units','--type=service',
              '--state=active,activating,deactivating','--output=json','--no-pager']
        units=rows(run(argv));stable=[]
        for unit in units:
            require(all(isinstance(unit.get(k),str) for k in ('unit','load','active','sub')) and
                    unit['unit'].endswith('.service'),'service inventory incomplete')
            stable.append({k:unit[k] for k in ('unit','load','active','sub')})
        require(len({x['unit'] for x in stable})==len(stable),'duplicate service inventory')
        actual['activeServiceInventory'][scope]=stable
    # Captured for the private baseline review. Sessions are not assumed to be
    # empty: the authorized SSH observer itself may have a session.
    actual['sessionInventory']=rows(run([SW+'loginctl','list-sessions','--json=short','--no-pager']))
    actual['interfaces'] = {}
    for nic in nics:
        value = rows(run([SW+'ip','-j','address','show','dev',nic]))
        require(len(value)==1 and value[0]['ifname']==nic and value[0]['address']==actual['macs'][nic], 'interface response mismatch')
        nm = run([SW+'nmcli','-g','GENERAL.CON-UUID,GENERAL.AUTOCONNECT','device','show',nic]).splitlines()
        require(len(nm)==2 and nm[1] in ('yes','no'), 'NM observation schema')
        v = value[0]
        result = dict(mac=v['address'], mtu=v['mtu'], adminUp='UP' in v['flags'],
                      addresses=sorted([{k:a[k] for k in ('family','local','prefixlen','scope')} for a in v['addr_info']],key=lambda a:json.dumps(a,sort_keys=True)),
                      uuid='' if nm[0]=='--' else nm[0],autoconnect=nm[1])
        if nic != cfg['managementInterface']:
            result['arp'] = [read('/proc/sys/net/ipv4/conf/'+nic+'/'+name) for name in ('arp_ignore','arp_announce')]
        actual['interfaces'][nic] = result
    if predeclared:
        nic=cfg['directInterface']
        speed=read('/sys/class/net/'+nic+'/speed')
        require(re.fullmatch('[0-9]+',speed) is not None,'direct speed observation schema')
        actual['directLink']=dict(carrier=read('/sys/class/net/'+nic+'/carrier'),speedMbps=int(speed),
                                  fec=fec_settings(run([SW+'ethtool','--show-fec',nic])),
                                  hca=hca_link(run([SW+'rdma','link','show']),cfg['hca'],nic))
    for family in ('4','6'):
        actual['routes'+family] = rows(run([SW+'ip','-j','-'+family,'route','show','table','all']))
        actual['rules'+family] = rows(run([SW+'ip','-j','-'+family,'rule','show']))
    actual['profileInventory'] = sorted(run([SW+'nmcli','-t','-f','NAME,UUID,TYPE','connection','show']).splitlines())
    actual['switchSettings'] = {}
    require(set(cfg['switchUuids']) == set(cfg['switchInterfaces']), 'switch UUID inventory')
    for nic, uuid in cfg['switchUuids'].items():
        require(re.fullmatch('[0-9a-f-]{36}',uuid) is not None, 'switch UUID format')
        values = run([SW+'nmcli','-g','connection.id,connection.interface-name,connection.autoconnect,ipv4.method,ipv4.addresses,ipv4.route-metric,ipv4.never-default,ipv6.method,802-3-ethernet.mtu','connection','show','uuid',uuid]).splitlines()
        require(len(values)==9 and values[1]==nic, 'saved switch settings identity')
        actual['switchSettings'][uuid] = values
    for family,binary in (('4','iptables'),('6','ip6tables')):
        # nf_tables does not provide the legacy /proc/net/ip*_tables_names.
        # No missing-file fallback: a complete successful save stream is required.
        names=firewall_tables(run([SUDO,'-n',SW+binary+'-save']))
        tables={}
        for table in sorted(names):
            value=run([SUDO,'-n',SW+binary,'-t',table,'-S']).splitlines()
            require(value and all(row.startswith(('-P ','-N ','-A ')) for row in value),'firewall table query incomplete')
            tables[table]=value
        require(firewall_tables(run([SUDO,'-n',SW+binary+'-save']))==names,'firewall table inventory changed during snapshot')
        actual['firewallTables'+family]=tables
        actual['firewall'+family]=tables['filter']
    return actual
