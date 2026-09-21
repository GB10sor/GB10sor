"""Per-node receiver for the private finite direct launch envelope.

All lifecycle entrypoints require sealed private state. The independent head
finalizer is distinct from the wrapper/controller it proves stopped. This source
has not yet passed the whole literal-command hardware rehearsal.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time


def require(ok,why):
    if not ok:raise RuntimeError(why)


def pairs(values):
    out={}
    for key,value in values:
        require(key not in out,'duplicate guard JSON key');out[key]=value
    return out


def read(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600 and info.st_size<=1048576,'private regular guard input')
        raw=stream.read(1048577);require(len(raw)<=1048576,'guard input grew');return raw


def digest(raw):return hashlib.sha256(raw).hexdigest()


def bootstrap(root,seal):
    root=Path(root)
    require(root.is_absolute() and root.resolve(strict=True)==root and root.stat().st_uid==os.getuid() and stat.S_IMODE(root.stat().st_mode)==0o700,'private canonical guard root')
    raw=read(root/'config.json');require(digest(raw)==seal,'guard configuration changed')
    cfg=json.loads(raw,object_pairs_hook=pairs)
    require(re.fullmatch('[0-9a-f]{64}',cfg['owner']) and read(root/'OWNER')==(cfg['owner']+'\n').encode(),'guard owner changed')
    needed={'deuces-direct-guard.py','deuces-direct-state.py','deuces-direct-lease.py','deuces-direct-inventory.py','deuces-owned-container.py',
            'deuces-direct-cleanup.py','deuces-direct-network.py','deuces-direct-phase.py','deuces-direct-snapshot.py'}
    require(needed<=set(cfg['sources']),'guard source inventory incomplete')
    for name,pin in cfg['sources'].items():
        require(re.fullmatch('[A-Za-z0-9._-]+',name) and name not in ('config.json','OWNER') and digest(read(root/name))==pin,'guard source changed')
    modules={}
    for name in needed-{'deuces-direct-guard.py'}:
        spec=importlib.util.spec_from_file_location(name,root/name);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);modules[name]=module
    state=modules['deuces-direct-state.py'].State(root,seal)
    return state,modules


def identity(cfg):
    persistent=cfg.get('persistentClosure',cfg['systemClosure']) if cfg.get('networkLifecycle','transient-switched')=='predeclared-direct' else cfg['systemClosure']
    require(Path('/proc/sys/kernel/random/boot_id').read_text().strip()==cfg['bootId'] and
            os.path.realpath('/run/current-system')==cfg['systemClosure'] and os.path.realpath('/nix/var/nix/profiles/system')==persistent,'guard boot/current/persistent closure changed')
    result=subprocess.run(['/run/current-system/sw/bin/hostname','-s'],cwd='/',capture_output=True,text=True,timeout=5)
    require(result.returncode==0 and result.stdout.strip()==cfg['hostname'],'guard hostname query failed/mismatch')
    for nic,mac in cfg['macs'].items():
        require(re.fullmatch('[A-Za-z0-9]+',nic) and Path('/sys/class/net/'+nic+'/address').read_text().strip()==mac,'guard physical interface changed')


def accept_inventory(state,modules,raw,identity_check=identity,lease_factory=None,absence_check=None):
    require(state.config.get('linkOnly',False) is False,'link-only envelope forbids every model resource declaration')
    require(len(raw)<=1048576,'bounded resource packet')
    packet=json.loads(raw,object_pairs_hook=pairs)
    inventory=modules['deuces-direct-inventory.py']
    container=modules['deuces-owned-container.py']
    lease_factory=modules['deuces-direct-lease.py'].Lease if lease_factory is None else lease_factory
    expected=state.config['inventoryExpected']
    verified=inventory.validate(packet,expected,container.validate_config)
    with state.lock():
        identity_check(state.config)
        require(not (state.root/'recovery-started.json').exists() and not (state.root/'model-inventory.json').exists(),'recovery/repeated model acknowledgement')
        phase=state.read('phase-direct-ready.json')
        require(phase.get('phase')=='direct-ready' and phase.get('profileUuid')==state.config['profileUuid'],'direct phase not parent-owned/ready')
        require(state.read('phase-firewall-ready.json').get('rules')==state.config['firewallRules'],'parent firewall not positively installed before model ACK')
        # Container/hash cleanup and network restoration both fit the ORIGINAL
        # guard deadline. No new deadline is manufactured for a late model.
        reserve=expected['maxModelLeaseSeconds']+state.config['rollbackExecutionSeconds']+state.config['rollbackStopSeconds']+60
        lease=lease_factory(state);lease.check(reserve)
        absence_check=modules['deuces-direct-cleanup.py'].pre_ack_absence if absence_check is None else absence_check
        absence_check(state,modules,verified)
        model_anchor=dict(version=1,invocationOwner=verified['declaration']['invocationOwner'],
                          runId=verified['declaration']['runId'],declarationSha256=verified['declarationSha256'])
        # Preserve exact original packet bytes (including both rank configs)
        # before publishing acknowledgement; roots/units remain only declared.
        S=modules['deuces-direct-state.py']
        S.publish(state.root,'model-inventory.json',raw)
        receipt=state.write('model-inventory-receipt.json',result='pass',declaration=model_anchor,inventorySha256=digest(raw))
        lease.check(reserve);identity_check(state.config)
        guard=dict(rank=state.config['rank'],host=state.config['host'],node=state.config['hostname'],stateRoot=str(state.root),configSha256=state.seal)
        return dict(version=1,result='pass',declaration=model_anchor,guard=guard,inventorySha256=digest(raw),
                    receiptSha256=digest(S.encode(receipt)))


def envelope(state,action,**fields):
    target=dict(rank=state.config['rank'],host=state.config['host'],node=state.config['hostname'],stateRoot=str(state.root),configSha256=state.seal)
    return dict(version=1,result='pass',owner=state.owner,guard=target,action=action,**fields)


def publish_exact(state,modules,name,value):
    S=modules['deuces-direct-state.py'];raw=S.encode(value)
    if (state.root/name).exists():require(S.read_file(state.root/name)==raw,'immutable relay record differs')
    else:S.publish(state.root,name,raw)
    return digest(raw)


def accept_closure(state,modules,action,packet):
    C=modules['deuces-direct-cleanup.py']
    with state.lock():
        if action=='accept-controller-closure':
            C.verify_controller_packet(state,modules,packet)
            # Permanent barrier is written before accepting any closure. The
            # frontend must check it before submitting this unique controller.
            publish_exact(state,modules,'launch-closed.json',dict(owner=state.owner,configSha256=state.seal,reason='controller-terminal'))
            pin=publish_exact(state,modules,'controller-closure.json',packet)
            publish_exact(state,modules,'controller-closure-receipt.json',dict(owner=state.owner,configSha256=state.seal,result='pass',packetSha256=pin))
            if packet['modelAckAbsent']:
                publish_exact(state,modules,'model-never-started.json',dict(owner=state.owner,configSha256=state.seal,result='pass',reason='closed-before-parent-ack',closureSha256=pin))
        else:
            require(action=='accept-pair-closure','unknown relay action')
            C.verify_pair_packet(state,modules,packet)
            C.verify_local_cleanup(state,modules)
            pin=publish_exact(state,modules,'pair-closure.json',packet)
            publish_exact(state,modules,'pair-closure-receipt.json',dict(owner=state.owner,configSha256=state.seal,result='pass',packetSha256=pin))
    return envelope(state,action,packetSha256=pin)


def accept_controller_start(state,modules,packet):
    C=modules['deuces-direct-cleanup.py'];cfg=state.config['controller']
    require(set(packet)=={'version','owner','headGuard','properties'} and packet['version']==1 and packet['owner']==state.owner and
            packet['headGuard']==C.pair(state)[0],'controller start source identity')
    now=packet['properties'];C.controller_policy(state,modules,now)
    require(now.get('ActiveState')=='active' and now.get('SubState')=='running' and
            re.fullmatch('[0-9a-f]{32}',now.get('InvocationID','')) and re.fullmatch('[1-9][0-9]*',now.get('MainPID','')) and
            now.get('ExecMainPID')==now['MainPID'] and now.get('ControlGroup','').startswith('/user.slice/') and
            now['ControlGroup'].endswith('/'+cfg['unit']),'controller executing identity missing')
    with state.lock():
        require(not any((state.root/name).exists() for name in ('launch-closed.json','phase-transition-started.json','recovery-started.json','controller-executing.json')),'controller start already consumed/closed')
        modules['deuces-direct-lease.py'].Lease(state).check(state.config['launchReserveSeconds'])
        state.write('controller-executing.json',invocationId=now['InvocationID'],pid=int(now['MainPID']),argv=cfg['argv'],unit=cfg['unit'],cgroup=now['ControlGroup'])
    return envelope(state,'accept-controller-start',invocationId=now['InvocationID'])


def accept_pair_armed(state,modules,packet):
    with state.lock():
        require(not any((state.root/name).exists() for name in ('launch-closed.json','phase-transition-started.json','recovery-started.json','controller-executing.json')),'armed relay arrived after phase boundary')
        modules['deuces-direct-cleanup.py'].verify_armed_packet(state,modules,packet)
        pin=publish_exact(state,modules,'pair-armed.json',packet)
        publish_exact(state,modules,'pair-armed-receipt.json',dict(owner=state.owner,configSha256=state.seal,result='pass',packetSha256=pin))
    return envelope(state,'accept-pair-armed',packetSha256=pin)


def status(state,modules,action):
    """Intentionally lock-free: Network may already hold this node's lock."""
    state.sources();C=modules['deuces-direct-cleanup.py']
    if action=='lease-status':
        value=modules['deuces-direct-lease.py'].Lease(state).check(0)
        observed=time.monotonic()
        return envelope(state,action,remainingSeconds=max(0,int(value['deadline']-observed)),
                        timerInvocation=value['timer']['InvocationID'],serviceState='inactive/dead/0',bootId=state.config['bootId'],
                        deadlineMonotonicSeconds=value['deadline'],observedMonotonicSeconds=observed)
    controller=C.replicated_controller(state,modules)
    if action=='controller-status':return envelope(state,action,controller=controller,stopped=True)
    require(action=='cleanup-status','unknown read-only status')
    resources=C.verify_local_cleanup(state,modules)
    return envelope(state,action,controller=controller,allDeclaredResourcesStopped=True,resources=resources)


def cleanup_resources(state,modules):
    C=modules['deuces-direct-cleanup.py']
    with state.lock():
        # A timer can always cancel its exact local resources, even if the head
        # relay has disappeared. Missing model roots still fail closed; this
        # never manufactures a post-ACK partial-stage absence pass.
        if not (state.root/'recovery-started.json').exists():state.write('recovery-started.json',reason='owned-cleanup')
        resources=C.cleanup_local(state,modules=modules)
        record=dict(owner=state.owner,configSha256=state.seal,result='pass',resources=resources)
        publish_exact(state,modules,'local-cleanup.json',record)
    C.verify_local_cleanup(state,modules)
    return envelope(state,'cleanup-resources',resources=resources)


def finalize(state,modules,request=None):
    """Independent head actor; never called from inside the model controller.

    No state lock is held while contacting either guard. Runtime stays bounded
    by the finalizer's own reviewed oneshot, and each remote operation has an
    explicit timeout. No network write precedes both positive cleanup replicas.
    """
    C=modules['deuces-direct-cleanup.py'];request=C.request if request is None else request
    require(state.config['rank']==0,'only head finalizer relays pair closure')
    cfg=state.config;peers=C.pair(state)
    local=cfg['localCleanupBudgetSeconds'];total=cfg['rollbackExecutionSeconds']
    require(type(local) is int and 240<=local<=1200 and total>=2*local+1200,'finalizer budget lacks pair cleanup/relay/restore reserve')
    now=C.controller_properties(state,modules)
    packet=C.closure_packet(state,modules,now) # refuses running controller
    for target in peers:request(state,target,'accept-controller-closure',payload=packet,timeout=20)
    errors=[]
    for target in peers:
        try:request(state,target,'cleanup-resources',timeout=local)
        except Exception as error:errors.append(str(error))
    require(not errors,'pair cleanup failed; keep independent guards: '+repr(errors))
    results=[request(state,target,'cleanup-status',timeout=20) for target in peers]
    pair_packet=dict(version=1,owner=state.owner,controller=packet['controller'],peers=results)
    C.verify_pair_packet(state,modules,pair_packet)
    for target in peers:request(state,target,'accept-pair-closure',payload=pair_packet,timeout=180)
    restored=[]
    for target in peers:restored.append(request(state,target,'restore',timeout=180))
    return envelope(state,'finalize',restored=restored)


def execute(state,modules,action,packet=None):
    if action=='accept-pair-armed':return accept_pair_armed(state,modules,packet)
    identity(state.config);state.sources()
    if action.endswith('-status'):return status(state,modules,action)
    if action=='preflight':
        network=modules['deuces-direct-network.py'].Network(state,modules)
        network.preflight()
        return envelope(state,action,baseline='predeclared-direct' if network.predeclared else 'switched')
    if action=='accept-controller-start':return accept_controller_start(state,modules,packet)
    if action in ('accept-controller-closure','accept-pair-closure'):return accept_closure(state,modules,action,packet)
    if action=='cleanup-resources':return cleanup_resources(state,modules)
    if action=='finalize':return finalize(state,modules)
    if action=='recover':
        # Head timers attempt the same independent finalizer; workers cancel
        # locally and only restore if the complete head relay already exists.
        if state.config['rank']==0:return finalize(state,modules)
        cleanup_resources(state,modules)
        modules['deuces-direct-network.py'].Network(state,modules).restore()
        return envelope(state,action,restored=True)
    if action=='restore':
        modules['deuces-direct-network.py'].Network(state,modules).restore()
        return envelope(state,action,restored=True)
    if action in ('lease-prepare','lease-arm','lease-disarm'):
        with state.lock():
            value=getattr(modules['deuces-direct-lease.py'].Lease(state),action.split('-')[1])()
        return envelope(state,action,lease=value)
    if action=='enter-idle':
        modules['deuces-direct-network.py'].Network(state,modules).enter_idle()
        return envelope(state,action,idle=True)
    if action=='firewall-ready':
        modules['deuces-direct-network.py'].Network(state,modules).install_firewall()
        return envelope(state,action,ready=True)
    if action=='direct-ready':
        with state.lock():
            value=modules['deuces-direct-network.py'].Network(state,modules).check('direct-or-idle')
            port=value['interfaces'][state.config['directInterface']]
            require(port['uuid']==state.config['profileUuid'] and port['addresses'] and port['mtu']==state.config['mtu'],'direct profile not actually active')
            modules['deuces-direct-lease.py'].Lease(state).check(state.config['launchReserveSeconds'])
            state.write('phase-direct-ready.json',phase='direct-ready',profileUuid=state.config['profileUuid'])
        return envelope(state,action,ready=True)
    raise RuntimeError('unknown fixed guard action')


def main():
    require(sys.flags.isolated and not sys.flags.optimize,'Python -I required')
    require(len(sys.argv)==4,'guard action root config-sha required')
    state,modules=bootstrap(sys.argv[2],sys.argv[3])
    action=sys.argv[1]
    if action=='accept-inventory':value=accept_inventory(state,modules,sys.stdin.buffer.read(1048577))
    elif action.startswith('accept-'):
        raw=sys.stdin.buffer.read(1048577);require(len(raw)<=1048576,'relay packet too large')
        value=execute(state,modules,action,json.loads(raw,object_pairs_hook=pairs))
    else:value=execute(state,modules,action)
    print(json.dumps(value,sort_keys=True))


if __name__=='__main__':main()
