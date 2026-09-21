"""Narrow direct-pair cleanup bridge. No traffic, models or profile changes.

The guard's fixed status protocol verifies both nodes before network restore.
Unknown controller, missing preparation or non-positive helper receipts fail
closed; this module never equates an empty GPU list with resource cleanup.
"""
import json
import hashlib
import os
import stat
from pathlib import Path
import re
import shlex
import subprocess
import time
import math


def result_command(argv,timeout=5):
    return subprocess.run(argv,cwd='/',timeout=timeout,text=True,capture_output=True)


def absent_resource(state,modules,kind,entry,container_cfg=None,query=result_command):
    """Positive exact absent root/unit/name observation, never a query failure."""
    root=Path(entry['stateRoot'])
    require(root.is_absolute() and '..' not in root.parts and root.parent.is_dir() and
            root.parent.resolve(strict=True)==root.parent,'resource parent changed/missing')
    try:root.lstat()
    except FileNotFoundError:pass
    else:raise RuntimeError('resource root exists; partial/unknown staging requires owned helper proof')
    if kind=='hash':units=[entry['unit']+'.service']
    else:
        require(kind=='container' and container_cfg is not None,'absent resource kind/config')
        units=[root.name+'-cleanup.timer',root.name+'-cleanup.service']
    props=[]
    for unit in units:
        argv=[state.config['systemctl'],'--user','show',unit,'-p','Id','-p','LoadState','-p','ActiveState','-p','SubState','-p','MainPID']
        response=query(argv,timeout=5)
        require(response.returncode in (0,4),'resource absence query failed')
        value=modules['deuces-direct-lease.py'].properties(response.stdout)
        require(value.get('Id')==unit and value.get('LoadState')=='not-found' and value.get('ActiveState')=='inactive' and
                value.get('SubState')=='dead' and (value.get('MainPID') in (None,'0') if unit.endswith('.timer') else value.get('MainPID')=='0'),
                'resource unit is present/unknown')
        props.append(value)
    name=None
    if kind=='container':
        name=container_cfg['name']
        response=query([container_cfg['tools']['podman'],'container','exists',name],timeout=5)
        require(response.returncode==1 and not response.stdout.strip() and not response.stderr.strip(),
                'container exists or existence query failed')
    # No concurrent actor may recreate a slot after controller closure, but the
    # second path read also catches an ordinary race in the pre-ACK baseline.
    try:root.lstat()
    except FileNotFoundError:pass
    else:raise RuntimeError('resource appeared during absence checks')
    return dict(kind=kind,stateRoot=str(root),units=props,containerName=name)


def pre_ack_absence(state,modules,verified,query=result_command):
    decl=verified['declaration'];rank=state.config['rank'];observations=[]
    for entry in decl['containers']:
        if entry['rank']==rank:
            cfg=next(x for x in verified['configs'] if x['rank']==rank)
            observations.append(absent_resource(state,modules,'container',entry,cfg,query))
    for entry in decl['hashes']:
        if entry['rank']==rank:observations.append(absent_resource(state,modules,'hash',entry,query=query))
    expected_count=1+sum(entry['rank']==rank for entry in decl['hashes'])
    require(len(observations)==expected_count,'local container/hash absence inventory incomplete')
    return state.write('model-pre-ack-absence.json',result='pass',declarationSha256=verified['declarationSha256'],observations=observations)


def never_created_slot(state,modules,item,entry,container_cfg=None,query=result_command):
    """Only a still-absent whole slot, after its sole controller is closed.

    An existing partial directory is deliberately NOT adopted. It remains a
    manual-recovery failure unless its ordinary exact-owned helper can stop it.
    """
    S=modules['deuces-direct-state.py'];controller=replicated_controller(state,modules)
    prior=state.read('model-pre-ack-absence.json');receipt=state.read('model-inventory-receipt.json')
    require(prior.get('result')=='pass' and prior.get('declarationSha256')==receipt['declaration']['declarationSha256'] and
            len([x for x in prior['observations'] if x['kind']==item['kind'] and x['stateRoot']==item['stateRoot']])==1,
            'slot had no exact pre-ACK absent baseline')
    observed=absent_resource(state,modules,item['kind'],entry,container_cfg,query)
    name='never-created-'+hashlib.sha256(item['stateRoot'].encode()).hexdigest()+'.json'
    record=dict(owner=state.owner,configSha256=state.seal,result='pass',resource=item,controller=controller,
                declarationSha256=prior['declarationSha256'],observation=observed)
    raw=S.encode(record)
    if (state.root/name).exists():require(S.read_file(state.root/name)==raw,'never-created receipt changed')
    else:S.publish(state.root,name,raw)
    return hashlib.sha256(raw).hexdigest()


def require(ok,why):
    if not ok:raise RuntimeError(why)


def run(argv,timeout=20,input=None):
    p=subprocess.run(argv,cwd='/',timeout=timeout,text=True,capture_output=True,input=input)
    require(p.returncode==0,'owned cleanup/status command failed: '+repr(argv)+': '+p.stderr[:2048])
    require(len(p.stdout.encode())<=1048576,'oversized cleanup response')
    return p.stdout


def pair(state):
    value=state.read('pair-guard-configurations.json')
    peers=value['peers'];require(isinstance(peers,list) and len(peers)==2 and {x.get('rank') for x in peers}=={0,1},'both configured guards required')
    for item in peers:
        require(set(item)=={'rank','host','node','stateRoot','configSha256'},'guard pair schema')
        expected=next(n for n in state.config['inventoryExpected']['nodes'] if n['rank']==item['rank'])
        require(all(item[k]==expected[k] for k in ('rank','host','node')) and re.fullmatch('[0-9a-f]{64}',item['configSha256']),'guard pair identity')
        root=Path(item['stateRoot']);require(root.is_absolute() and '..' not in root.parts,'guard pair root')
        if item['rank']==state.config['rank']:require(root==state.root and item['configSha256']==state.seal,'own pair config mismatch')
    return sorted(peers,key=lambda p:p['rank'])


def request(state,target,action,runner=run,payload=None,timeout=20):
    readonly=('lease-status','controller-status','cleanup-status')
    require(action in (*readonly,'accept-controller-closure','accept-pair-closure','cleanup-resources','restore'),'fixed control action')
    require((payload is not None)==action.startswith('accept-'),'control payload/action mismatch')
    require(type(timeout) is int and 1<=timeout<=3600 and (action not in readonly or timeout<=20),'bounded control request')
    extra={} if payload is None else dict(input=json.dumps(payload,sort_keys=True,separators=(',',':'))+'\n')
    remote=[state.config['controlTransport']['pythonByRank'][str(target['rank'])],'-I','-B',
            str(Path(target['stateRoot'])/'deuces-direct-guard.py'),action,target['stateRoot'],target['configSha256']]
    # A held Network lock must not recursively acquire itself, and local
    # control does not depend on SSH authorization to the same host. All status
    # handlers below are read-only and lock-free; the receiver rechecks identity.
    if target['rank']==state.config['rank']:
        require(target['stateRoot']==str(state.root) and target['configSha256']==state.seal,'local status target changed')
        value=json.loads(runner(remote,timeout=timeout,**extra))
        require(value.get('version')==1 and value.get('result')=='pass' and value.get('owner')==state.owner and
                value.get('guard')==target and value.get('action')==action,'foreign/incomplete local status')
        return value
    t=state.config['controlTransport']
    require(set(t)=={'ssh','identity','knownHosts','knownHostsSha256','pythonByRank'},'guard control transport schema')
    require(re.fullmatch('/nix/store/[A-Za-z0-9._+-]+/bin/ssh',t['ssh']),'fixed SSH binary')
    for field,private in (('identity',True),('knownHosts',False)):
        path=Path(t[field]);require(path.is_absolute() and path.resolve(strict=True)==path,'canonical existing SSH input')
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'rb') as stream:
            info=os.fstat(stream.fileno());require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and not info.st_mode & (0o077 if private else 0o022) and info.st_size<=1048576,'protected owned SSH input')
            if not private:require(hashlib.sha256(stream.read(1048577)).hexdigest()==t['knownHostsSha256'],'trusted host pins changed')
    # The sealed receiver rechecks its source, state owner, boot and closure.
    # Host pins are never learned on demand and no reverse-SSH success assumed.
    require(re.fullmatch('[A-Za-z0-9_.@:-]+',target['host']) and not target['host'].startswith('-'),'exact peer host')
    argv=[t['ssh'],'-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5','-o','ConnectionAttempts=1',
          '-o','ServerAliveInterval=5','-o','ServerAliveCountMax=1','-o','UserKnownHostsFile='+t['knownHosts'],'-i',t['identity'],target['host'],shlex.join(remote)]
    value=json.loads(runner(argv,timeout=timeout,**extra))
    require(value.get('version')==1 and value.get('result')=='pass' and value.get('owner')==state.owner and value.get('guard')==target and value.get('action')==action,'foreign/incomplete guard status')
    return value


def expected_resources(state,target):
    expected=[]
    for slot in state.config['linkPlan']['slots']:
        if slot['host']==target['host']:
            expected.append(dict(kind='link',stateRoot=slot['state'],configOrTokenSha256=slot['configSha256']))
    require(len(expected)==4,'four exact one-rail link slots per node required')
    # No inventory may count as never-started only with a positive head-relay
    # tombstone issued after exact controller closure and absent parent ACK.
    if (state.root/'model-never-started.json').exists():
        tombstone=state.read('model-never-started.json')
        require(tombstone.get('result')=='pass' and tombstone.get('reason')=='closed-before-parent-ack' and
                re.fullmatch('[0-9a-f]{64}',tombstone.get('closureSha256','')),'invalid never-started model tombstone')
        raw=helper_file(state.root/'controller-closure.json',tombstone['closureSha256'])
        closure=json.loads(raw);saved=state.read('controller-closure-receipt.json')
        require(saved.get('result')=='pass' and saved.get('packetSha256')==tombstone['closureSha256'] and
                closure.get('owner')==state.owner and closure.get('modelAckAbsent') is True and
                closure.get('headGuard')==pair(state)[0],'never-started tombstone lacks closed-before-ACK relay')
        expected.append(dict(kind='never-started-model',stateRoot=target['stateRoot'],configOrTokenSha256=state.owner))
        return sorted(expected,key=lambda x:(x['kind'],x['stateRoot']))
    receipt=state.read('model-inventory-receipt.json')
    root=state.root/'model-inventory.json';require(root.is_file() and not root.is_symlink() and root.stat().st_size<=1048576,'model inventory absent/unsafe')
    raw=root.read_bytes();require(hashlib.sha256(raw).hexdigest()==receipt['inventorySha256'],'model inventory receipt changed')
    packet=json.loads(raw);decl=json.loads(packet['declaration'])
    require(hashlib.sha256(packet['declaration'].encode()).hexdigest()==receipt['declaration']['declarationSha256'],'model declaration changed')
    for container in decl['containers']:
        if container['rank']==target['rank']:
            require(container['host']==target['host'] and container['node']==target['node'],'container host/rank changed')
            expected.append(dict(kind='container',stateRoot=container['stateRoot'],configOrTokenSha256=container['configSha256']))
    require(sum(x['kind']=='container' for x in expected)==1,'one exact container per node')
    for item in decl['hashes']:
        if item['rank']==target['rank']:
            require(item['host']==target['host'],'hash host/rank changed')
            expected.append(dict(kind='hash',stateRoot=item['stateRoot'],configOrTokenSha256=item['token']))
    require(any(x['kind']=='hash' for x in expected),'declared hashes missing')
    return sorted(expected,key=lambda x:(x['kind'],x['stateRoot']))


def helper_file(path,pin):
    path=Path(path)
    require(path.is_absolute() and path.resolve(strict=True)==path,'canonical owned helper input')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno());require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and not info.st_mode & 0o022 and info.st_size<=1048576,'protected owned helper input')
        raw=stream.read(1048577);require(len(raw)<=1048576 and hashlib.sha256(raw).hexdigest()==pin,'owned helper input changed');return raw


def cleanup_links(state,runner=run):
    """Every pre-staged local link slot is stopped before reporting failures."""
    plan=state.config['linkPlan'];errors=[];resources=[]
    slots=[x for x in plan['slots'] if x['host']==state.config['host']]
    require(len(slots)==4,'four complete pre-staged local link slots required')
    for slot in slots:
        try:
            root=Path(slot['state']);cfg=slot['config']
            require(root.is_dir() and root.resolve(strict=True)==root,'pre-staged link root missing/indirect')
            helper_file(root/'worker.py',plan['helperSha256']);helper_file(root/'config.json',slot['configSha256'])
            require((root/'OWNER').read_text()==plan['owner']+'\n','link owner changed')
            base=[cfg['python'],'-I','-B',str(root/'worker.py')]
            stopped=json.loads(runner([*base,'stop',str(root),slot['configSha256']],timeout=cfg['stopSeconds']+30))
            require(stopped.get('result')=='pass' and stopped.get('owner')==plan['owner'] and stopped.get('configSha256')==slot['configSha256'],'link helper stop not positive')
            require(json.loads(runner([*base,'inspect',str(root),slot['configSha256']],timeout=20)) is None,'link remains active/unknown')
            receipt=(root/'stopped.json').read_bytes()
            require(json.loads(receipt)==stopped,'link stop receipt changed')
            resources.append(dict(kind='link',stateRoot=str(root),configOrTokenSha256=slot['configSha256'],receiptSha256=hashlib.sha256(receipt).hexdigest()))
        except Exception as error:errors.append(slot['label']+': '+str(error))
    require(not errors,'owned link cleanup failed: '+repr(errors))
    return resources


def cleanup_models(state,runner=run,modules=None):
    """Stop only the exact declared local container/hashes; preserve receipts."""
    target=next(x for x in pair(state) if x['rank']==state.config['rank'])
    wanted=[x for x in expected_resources(state,target) if x['kind']!='link']
    if len(wanted)==1 and wanted[0]['kind']=='never-started-model':
        raw=(state.root/'model-never-started.json').read_bytes()
        return [dict(wanted[0],receiptSha256=hashlib.sha256(raw).hexdigest())]
    packet=json.loads((state.root/'model-inventory.json').read_bytes());decl=json.loads(packet['declaration'])
    resources=[];errors=[]
    for item in wanted:
        try:
            root=Path(item['stateRoot'])
            if not root.exists() and not root.is_symlink() and modules is not None:
                entry=next(x for x in decl['containers' if item['kind']=='container' else 'hashes'] if x['stateRoot']==str(root))
                cfg=json.loads(next(x['text'] for x in packet['configs'] if x['rank']==state.config['rank'])) if item['kind']=='container' else None
                pin=never_created_slot(state,modules,item,entry,cfg)
                resources.append(dict(item,receiptSha256=pin));continue
            require(root.is_dir() and root.resolve(strict=True)==root,'declared resource root missing/indirect; no generic absence pass')
            if item['kind']=='container':
                entry=next(x for x in decl['containers'] if x['rank']==state.config['rank'])
                raw=helper_file(root/'config.json',entry['configSha256']);cfg=json.loads(raw)
                helper_file(root/'worker.py',decl['sourceSha256']['containerHelper'])
                require((root/'OWNER').read_text()==decl['invocationOwner']+'\n','container owner changed')
                base=[cfg['python'],'-I','-B',str(root/'worker.py')]
                # A fired independent guard is its own original evidence; do
                # not overwrite it by rerunning cleanup.
                if not (root/'cleanup.json').exists():runner([*base,'cleanup',str(root),entry['configSha256']],timeout=cfg['cleanupSeconds']+30)
                cleanup=json.loads((root/'cleanup.json').read_bytes())
                require(cleanup.get('owner')==decl['invocationOwner'] and cleanup.get('configSha256')==entry['configSha256'] and cleanup.get('result')=='pass' and cleanup.get('errors')==[],'container cleanup receipt not positive')
                require(json.loads(runner([*base,'inspect',str(root),entry['configSha256']],timeout=30)) is None,'container still present/unknown')
                disarm=json.loads(runner([*base,'disarm',str(root),entry['configSha256']],timeout=180))
                require(disarm.get('result')=='pass' and disarm.get('owner')==decl['invocationOwner'] and disarm.get('configSha256')==entry['configSha256'],'container guard disarm failed')
                final=(root/'disarmed.json').read_bytes()
            else:
                entry=next(x for x in decl['hashes'] if x['stateRoot']==str(root))
                helper_file(root/'hash.sh',entry['helperSha256'])
                require((root/'owner').read_text().strip()==entry['token'],'hash owner changed')
                result=runner(['/run/current-system/sw/bin/bash',str(root/'hash.sh'),'stop',str(root),entry['unit'],entry['token']],timeout=90).strip()
                require(result in ('never-started','owned-unit-stopped-empty','owned-unit-already-stopped-empty'),'hash exact stop proof missing')
                final=(root/'stop.receipt').read_bytes() if (root/'stop.receipt').exists() else (root/'cancelled').read_bytes()
            resources.append(dict(item,receiptSha256=hashlib.sha256(final).hexdigest()))
        except Exception as error:errors.append(item['kind']+': '+str(error))
    require(not errors,'owned model/hash cleanup failed: '+repr(errors))
    return resources


def cleanup_local(state,runner=run,modules=None):
    """Independent guards try BOTH classes even if the first class fails."""
    state.sources();errors=[];resources=[]
    for operation in (cleanup_links,cleanup_models):
        try:resources.extend(operation(state,runner,modules) if operation is cleanup_models else operation(state,runner))
        except Exception as error:errors.append(str(error))
    require(not errors,'local resource cleanup failed; no network restore: '+repr(errors))
    return resources


def verify_hash_closed(state,modules,entry,runner=run):
    """Read-only recheck of a positive stop/cancellation; never touches marker."""
    S=modules['deuces-direct-state.py'];L=modules['deuces-direct-lease.py'];root=S.directory(entry['stateRoot'])
    helper_file(root/'hash.sh',entry['helperSha256'])
    require(S.read_file(root/'owner').strip()==entry['token'].encode(),'hash token changed')
    require((root/'cancelled').is_file() and not (root/'cancelled').is_symlink(),'hash lacks irreversible cancel marker')
    names=('Id','LoadState','ActiveState','SubState','MainPID','InvocationID','Description','ExecStart','ControlGroup','KillMode')
    argv=[state.config['systemctl'],'--user','show',entry['unit']+'.service',*[x for key in names for x in ('-p',key)]]
    if runner is run:
        queried=result_command(argv,timeout=15)
        require(queried.returncode in (0,4),'hash unit query failed')
        now=L.properties(queried.stdout)
        require(queried.returncode==0 or now.get('LoadState')=='not-found','loaded hash query failed')
    else:now=L.properties(runner(argv,timeout=15))
    require(now.get('Id')==entry['unit']+'.service' and now.get('MainPID')=='0' and
            (now.get('ActiveState'),now.get('SubState')) in (('inactive','dead'),('failed','failed')),'hash still active/unknown')
    if (root/'stop.receipt').exists():
        expected={'before-stop.txt','after-stop.txt','stop.receipt','expected-argv','expected-argv.sha256'}
        records=S.read_file(root/'stop-proof.sha256').decode().splitlines();seen=set()
        for row in records:
            require(re.fullmatch('[0-9a-f]{64}  [A-Za-z0-9.-]+',row),'hash stop manifest schema')
            pin,name=row.split('  ');require(name in expected and name not in seen,'hash stop manifest inventory')
            require(hashlib.sha256(S.read_file(root/name)).hexdigest()==pin,'hash stop leaf changed');seen.add(name)
        require(seen==expected,'hash stop manifest incomplete')
        stop=S.read_file(root/'stop.receipt').decode().splitlines()
        require(len(stop)==5 and stop[:2]==[entry['token'],entry['unit']] and re.fullmatch('[0-9a-f]{32}',stop[2]) and
                stop[4]=='owned-unit-stopped-empty','hash stop identity')
        before=L.properties(S.read_file(root/'before-stop.txt').decode())
        require(before.get('InvocationID')==stop[2] and before.get('Description')=='GB10 owned weight hash '+entry['token'] and before.get('KillMode')=='control-group','hash before-stop ownership')
        require(stop[3].endswith('/'+entry['unit']+'.service'),'hash recorded cgroup suffix')
        S.cgroup_empty(stop[3])
        require(now.get('LoadState') in ('loaded','not-found'),'hash load query failed')
        if now['LoadState']=='loaded':
            require(now.get('Description')==before['Description'] and now.get('KillMode')=='control-group' and
                    now.get('InvocationID') in ('',stop[2]) and now.get('ControlGroup') in ('',stop[3]),'hash replaced since stop')
            argv=S.read_file(root/'expected-argv').decode().strip().split(' ')
            L.exact_exec(now.get('ExecStart',''),argv)
        else:require(now['ActiveState']=='inactive' and now['SubState']=='dead','collected hash state malformed')
        return hashlib.sha256(S.read_file(root/'stop.receipt')).hexdigest()
    require(now.get('LoadState')=='not-found' and now['ActiveState']=='inactive' and now['SubState']=='dead' and
            not any((root/name).exists() for name in ('start-attempted','identity.txt','before-stop.txt')),
            'hash absence is not positive never-started proof')
    return hashlib.sha256(S.read_file(root/'cancelled')).hexdigest()


def verify_local_cleanup(state,modules,runner=run):
    """Lock-free readback after cleanup, safe from an already-held Network lock.

    Every helper action is an inspect, except repeated disarm which is allowed
    only when its immutable positive disarmed.json already exists. That helper
    branch only revalidates identity, groups and inactive units; no stop/write.
    """
    S=modules['deuces-direct-state.py'];saved=state.read('local-cleanup.json')
    require(saved.get('result')=='pass','no positive local cleanup')
    target=next(p for p in pair(state) if p['rank']==state.config['rank'])
    expected=expected_resources(state,target);resources=saved['resources']
    require(isinstance(resources,list) and sorted([{k:v for k,v in x.items() if k!='receiptSha256'} for x in resources],key=lambda x:(x['kind'],x['stateRoot']))==expected,'cleanup inventory differs')
    packet=json.loads(S.read_file(state.root/'model-inventory.json')) if (state.root/'model-inventory.json').exists() else None
    decl=json.loads(packet['declaration']) if packet else None
    for item in resources:
        root=Path(item['stateRoot'])
        tombstone=state.root/('never-created-'+hashlib.sha256(item['stateRoot'].encode()).hexdigest()+'.json')
        if item['kind'] in ('container','hash') and tombstone.exists():
            entry=next(x for x in decl['containers' if item['kind']=='container' else 'hashes'] if x['stateRoot']==str(root))
            cfg=json.loads(next(x['text'] for x in packet['configs'] if x['rank']==state.config['rank'])) if item['kind']=='container' else None
            # With an existing identical immutable tombstone this operation is
            # read-only and freshly refuses any appeared path/unit/container.
            require(never_created_slot(state,modules,{k:v for k,v in item.items() if k!='receiptSha256'},entry,cfg)==item['receiptSha256'],
                    'never-created slot proof changed')
            continue
        if item['kind']=='link':
            slot=next(x for x in state.config['linkPlan']['slots'] if x['state']==str(root));cfg=slot['config']
            helper_file(root/'worker.py',state.config['linkPlan']['helperSha256']);helper_file(root/'config.json',slot['configSha256'])
            raw=S.read_file(root/'stopped.json')
            require(hashlib.sha256(raw).hexdigest()==item['receiptSha256'],'link cleanup changed')
            require(json.loads(runner([cfg['python'],'-I','-B',str(root/'worker.py'),'inspect',str(root),slot['configSha256']],timeout=20)) is None,'link not stopped')
        elif item['kind']=='container':
            entry=next(x for x in decl['containers'] if x['rank']==state.config['rank'])
            cfg=json.loads(helper_file(root/'config.json',entry['configSha256']));helper_file(root/'worker.py',decl['sourceSha256']['containerHelper'])
            raw=S.read_file(root/'disarmed.json');require(hashlib.sha256(raw).hexdigest()==item['receiptSha256'],'container cleanup changed')
            require(json.loads(raw).get('result')=='pass','no prior disarm')
            value=json.loads(runner([cfg['python'],'-I','-B',str(root/'worker.py'),'disarm',str(root),entry['configSha256']],timeout=60))
            require(value==json.loads(raw),'container inactive recheck changed')
        elif item['kind']=='hash':
            entry=next(x for x in decl['hashes'] if x['stateRoot']==str(root))
            require(verify_hash_closed(state,modules,entry,runner)==item['receiptSha256'],'hash cleanup changed')
        else:
            require(item['kind']=='never-started-model' and hashlib.sha256(S.read_file(state.root/'model-never-started.json')).hexdigest()==item['receiptSha256'],'never-started proof changed')
    return resources


def verify_armed_packet(state,modules,packet,clock=time.monotonic):
    """Validate head-relayed pair status, without any worker reverse SSH."""
    peers=pair(state)
    require(set(packet)=={'version','owner','peers'} and packet['version']==1 and packet['owner']==state.owner and
            isinstance(packet['peers'],list) and len(packet['peers'])==2,'both armed guards required')
    observed=[]
    for target in peers:
        found=[x for x in packet['peers'] if x.get('guard')==target];require(len(found)==1,'one-sided/duplicate armed guard')
        value=found[0]
        require(value.get('version')==1 and value.get('owner')==state.owner and value.get('result')=='pass' and
                value.get('action')=='lease-status' and value.get('serviceState')=='inactive/dead/0' and
                value.get('bootId')==state.config['peerBootIds'][target['host']] and
                re.fullmatch('[a-f0-9]{32}',value.get('timerInvocation','')),'armed guard identity/policy')
        for key in ('deadlineMonotonicSeconds','observedMonotonicSeconds'):
            require(type(value.get(key)) in (int,float) and math.isfinite(value[key]) and value[key]>0,'finite original lease clock')
        delta=value['deadlineMonotonicSeconds']-value['observedMonotonicSeconds']
        require(type(value.get('remainingSeconds'))is int and value['remainingSeconds']>0 and
                0<=delta-value['remainingSeconds']<2,'lease clock/remaining disagreement')
        observed.append(value)
    own=observed[state.config['rank']]
    # Monotonic clocks from different boots are NEVER compared. Both head
    # queries/replications have a120s total bound; deduct that entire allowance
    # from peer remaining time plus elapsed time on this node's own clock.
    elapsed=clock()-own['observedMonotonicSeconds']
    require(elapsed>=0,'future local lease observation')
    for value in observed:
        require(value['remainingSeconds']-elapsed-120>=state.config['launchReserveSeconds'],'stale/insufficient paired lease')
    live=modules['deuces-direct-lease.py'].Lease(state).check(state.config['launchReserveSeconds'])
    require(live['timer']['InvocationID']==own['timerInvocation'] and live['deadline']==own['deadlineMonotonicSeconds'],'local timer replaced or original deadline changed')
    return packet


def verify_pair_armed(state,modules):
    state.sources();S=modules['deuces-direct-state.py'];raw=S.read_file(state.root/'pair-armed.json')
    receipt=state.read('pair-armed-receipt.json')
    require(receipt.get('result')=='pass' and receipt.get('packetSha256')==hashlib.sha256(raw).hexdigest(),'pair armed receipt absent/changed')
    return verify_armed_packet(state,modules,json.loads(raw))


def verify_pair_stopped(state,runner=run,modules=None):
    if modules is not None:
        # Independent finalizer has already relayed identical both-node proof.
        # No recursive lock, self-SSH or reverse worker→head connection here.
        S=modules['deuces-direct-state.py'];raw=S.read_file(state.root/'pair-closure.json')
        receipt=state.read('pair-closure-receipt.json')
        require(receipt.get('result')=='pass' and receipt.get('packetSha256')==hashlib.sha256(raw).hexdigest(),'pair closure changed')
        packet=verify_pair_packet(state,modules,json.loads(raw))
        verify_local_cleanup(state,modules,runner)
        return packet
    # Kept as a read-only diagnostic cross-query for the pure protocol tests.
    # Network's runtime path always passes modules and requires the replica.
    state.sources();peers=pair(state)
    controller=request(state,peers[0],'controller-status',runner)
    require(controller.get('stopped') is True and isinstance(controller.get('controller'),dict) and
            re.fullmatch('[0-9a-f]{32}',controller['controller'].get('invocationId','')) and controller['controller'].get('cgroupEmpty') is True,'controller has no exact terminal proof')
    results=[]
    for target in peers:
        value=request(state,target,'cleanup-status',runner)
        require(value.get('controller')==controller['controller'] and value.get('allDeclaredResourcesStopped') is True and
                isinstance(value.get('resources'),list) and len(value['resources'])>=4,'incomplete local resource proof')
        require(all(set(item)=={'kind','stateRoot','configOrTokenSha256','receiptSha256'} and item['kind'] in ('link','container','hash','never-started-model') and
                    Path(item['stateRoot']).is_absolute() and re.fullmatch('[0-9a-f]{64}',item['configOrTokenSha256']) and
                    re.fullmatch('[0-9a-f]{64}',item['receiptSha256']) for item in value['resources']),'resource receipt identity missing')
        actual=sorted([{k:v for k,v in item.items() if k!='receiptSha256'} for item in value['resources']],key=lambda x:(x['kind'],x['stateRoot']))
        require(actual==expected_resources(state,target),'missing/duplicated/foreign resource in peer cleanup proof')
        results.append(value)
    return dict(controller=controller,peers=results)


def controller_properties(state,modules,runner=run):
    cfg=state.config['controller'];L=modules['deuces-direct-lease.py']
    require(re.fullmatch('gb10sor-direct-controller-[0-9a-f]{32}\\.service',cfg['unit']),'exact controller unit')
    names=('Id','LoadState','Description','InvocationID','ActiveState','SubState','MainPID','ControlGroup','Result','ExecMainPID','ExecMainCode','ExecMainStatus','Type','RemainAfterExit','Restart','KillMode','WorkingDirectory','ExecStart','RuntimeMaxUSec','TimeoutStartUSec','TimeoutStopUSec')
    # systemctl show of a missing unit may return4. A caller cannot count that
    # as absence without a prior exact saved stop proof; run() rejects it.
    return L.properties(runner([state.config['systemctl'],'--user','show',cfg['unit'],*[x for key in names for x in ('-p',key)]],timeout=15))


def controller_policy(state,modules,now):
    cfg=state.config['controller'];L=modules['deuces-direct-lease.py']
    require(now.get('Id')==cfg['unit'] and now.get('LoadState')=='loaded' and now.get('Description')==state.owner,'controller unit ownership')
    L.exact_exec(now.get('ExecStart',''),cfg['argv'])
    for key,val in dict(Type='exec',RemainAfterExit='yes',Restart='no',KillMode='control-group',WorkingDirectory='/').items():require(now.get(key)==val,'controller policy changed')
    for key,seconds in (('RuntimeMaxUSec',cfg['runtimeSeconds']),('TimeoutStartUSec',15),('TimeoutStopUSec',cfg['stopSeconds'])):
        require(type(seconds)is int and seconds>0 and L.duration(now.get(key))==seconds*1000000,'controller bound changed')


def controller_terminal(state,modules,now):
    saved=state.read('controller-executing.json');cfg=state.config['controller']
    require(re.fullmatch('[0-9a-f]{32}',saved.get('invocationId','')) and type(saved.get('pid')) is int and saved['pid']>0 and
            saved.get('argv')==cfg['argv'] and saved.get('unit')==cfg['unit'],'saved controller execution identity')
    group=saved.get('cgroup','');require(group.startswith('/user.slice/') and group.endswith('/'+cfg['unit']),'controller recorded group')
    require(now.get('MainPID')=='0' and (now.get('ActiveState'),now.get('SubState')) in (('active','exited'),('inactive','dead'),('failed','failed')),'controller still active/unknown')
    controller_policy(state,modules,now)
    require(now.get('InvocationID')==saved['invocationId'] and now.get('ExecMainPID')==str(saved['pid']) and now.get('ControlGroup') in ('',group),'controller invocation/PID history changed')
    if (now['ActiveState'],now['SubState'])==('active','exited'):
        require(now.get('Result')=='success' and now.get('ExecMainCode')=='1' and now.get('ExecMainStatus')=='0','controller natural exit history missing')
    else:
        require(now.get('Result') in ('success','exit-code','signal','timeout','core-dump','watchdog'),'unknown stopped controller result')
    modules['deuces-direct-state.py'].cgroup_empty(group)
    return dict(unit=cfg['unit'],invocationId=saved['invocationId'],pid=saved['pid'],cgroup=group,cgroupEmpty=True)


def closure_packet(state,modules,now):
    """Head only, after actual positive terminal and empty-group observation."""
    require(state.config['rank']==0,'only head can observe controller closure')
    controller=controller_terminal(state,modules,now)
    saved=state.read('controller-executing.json')
    parent=Path(state.config['modelParentState'])
    require(parent.is_absolute() and '..' not in parent.parts,'exact model parent state path')
    # This is evaluated only after the complete controller cgroup is empty.
    # Parent ACK cannot be written by a surviving parent/child after this point.
    absent=not (parent/'parent-channel'/'ack.json').exists()
    return dict(version=1,owner=state.owner,headGuard=pair(state)[0],controller=controller,
                executing={k:v for k,v in saved.items() if k not in ('owner','configSha256')},
                properties=now,modelAckAbsent=absent)


def verify_controller_packet(state,modules,packet):
    """Validate relayed head evidence against pre-distributed exact identity.

    The worker does not claim it observed the head's cgroup locally. It accepts
    the authenticated head relay, pinned to the same immutable execution record.
    """
    require(set(packet)=={'version','owner','headGuard','controller','executing','properties','modelAckAbsent'} and
            packet['version']==1 and packet['owner']==state.owner and packet['headGuard']==pair(state)[0] and
            type(packet['modelAckAbsent']) is bool,'controller closure packet schema/owner')
    saved=state.read('controller-executing.json')
    require(packet['executing']=={k:v for k,v in saved.items() if k not in ('owner','configSha256')},'relayed controller execution differs from prior replica')
    now=packet['properties'];controller_policy(state,modules,now)
    require(now.get('MainPID')=='0' and now.get('InvocationID')==saved['invocationId'] and
            now.get('ExecMainPID')==str(saved['pid']) and now.get('ControlGroup') in ('',saved['cgroup']) and
            (now.get('ActiveState'),now.get('SubState')) in (('active','exited'),('inactive','dead'),('failed','failed')),
            'relayed controller not exact terminal identity')
    if now['ActiveState']=='active':
        require(now.get('Result')=='success' and now.get('ExecMainCode')=='1' and now.get('ExecMainStatus')=='0','relayed natural exit lacks success history')
    else:require(now.get('Result') in ('success','exit-code','signal','timeout','core-dump','watchdog'),'relayed terminal cause unknown')
    expected=dict(unit=saved['unit'],invocationId=saved['invocationId'],pid=saved['pid'],cgroup=saved['cgroup'],cgroupEmpty=True)
    require(packet['controller']==expected,'relayed controller closure fields mismatch')
    return expected


def replicated_controller(state,modules):
    S=modules['deuces-direct-state.py'];raw=S.read_file(state.root/'controller-closure.json')
    receipt=state.read('controller-closure-receipt.json')
    require(receipt.get('result')=='pass' and receipt.get('packetSha256')==hashlib.sha256(raw).hexdigest(),'controller relay seal changed')
    return verify_controller_packet(state,modules,json.loads(raw))


def verify_pair_packet(state,modules,packet):
    require(set(packet)=={'version','owner','controller','peers'} and packet['version']==1 and packet['owner']==state.owner and
            packet['controller']==replicated_controller(state,modules),'pair closure not same head proof')
    require(isinstance(packet['peers'],list) and len(packet['peers'])==2,'both cleanup peers required')
    for target in pair(state):
        matches=[x for x in packet['peers'] if x.get('guard')==target]
        require(len(matches)==1,'missing/duplicated cleanup guard')
        value=matches[0]
        require(value.get('version')==1 and value.get('owner')==state.owner and value.get('result')=='pass' and
                value.get('action')=='cleanup-status' and value.get('allDeclaredResourcesStopped') is True and
                value.get('controller')==packet['controller'],'invalid relayed peer cleanup')
        resources=value.get('resources');require(isinstance(resources,list),'resource list required')
        require(all(set(x)=={'kind','stateRoot','configOrTokenSha256','receiptSha256'} and
                    re.fullmatch('[a-f0-9]{64}',x.get('receiptSha256','')) for x in resources),'cleanup leaf schema')
        actual=sorted([{k:v for k,v in x.items() if k!='receiptSha256'} for x in resources],key=lambda x:(x['kind'],x['stateRoot']))
        require(actual==expected_resources(state,target),'relayed resource inventory differs')
    return packet
