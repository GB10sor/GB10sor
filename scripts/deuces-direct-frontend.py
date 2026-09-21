"""Finite multi-model direct-pair frontend for a provisioned Nix command.

Machine provisioning supplies identity, tool and network baseline pins. Each
invocation derives fresh link slots, guard state and ACK configuration; the
legacy switched path derives UUIDs while explicit predeclared-direct consumes
sealed Nix-owned UUIDs without adopting their lifecycle.
users do not supply per-run plan paths or owners. No OS/NAS operations exist.
This candidate still requires independent source and hardware review.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import shlex
import stat
import subprocess
import sys
import time
import uuid

HERE=Path(__file__).resolve().parent
MACHINE_PROFILE='laguna-s21-nvfp4'
PROFILE=os.environ.get('GB10_MODEL_PROFILE',MACHINE_PROFILE)
DIRECT_PROFILES={
 'laguna-s21-nvfp4','qwen38-flash-next-direct-bounded','qwen38-flash-next-nvidia-vllm',
 'deepseek-v4-sglang-target-only','deepseek-v4-nvidia-anemll-vllm','deepseek-v4-flash-0731-nvidia-vllm','deepseek-v4-flash-0731-nvidia-v028',
 'deepseek-v41-flash-exl3-29bpw',
 'inkling-small-nvfp4-sglang-dspark','glm53-flash-nvfp4-sglang-dflash2',
 'glm53-flash-nvfp4-sglang-target-only'
}
GUARD_SOURCES=('deuces-direct-guard.py','deuces-direct-state.py','deuces-direct-lease.py','deuces-direct-inventory.py',
 'deuces-direct-cleanup.py','deuces-direct-network.py','deuces-direct-phase.py','deuces-direct-snapshot.py','deuces-owned-container.py')


def need(ok,why):
    if not ok:raise RuntimeError(why)

def encoded(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
def sha(raw):return hashlib.sha256(raw).hexdigest()
def module(path):
    spec=importlib.util.spec_from_file_location(path.stem,path);value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

def private(path):
    path=Path(path);need(path.is_absolute() and path.resolve(strict=True)==path,'canonical provisioning input required')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno());need(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600 and info.st_size<=4194304,'private owned provisioning/receipt input')
        return stream.read(4194305)


def bootstrap_parents(home):
    """Only fixed per-user directories; never chmod an existing broad parent."""
    home=Path(home)
    need(home.is_absolute() and home.resolve(strict=True)==home and home.is_dir() and home.stat().st_uid==os.getuid() and
         not stat.S_IMODE(home.stat().st_mode)&0o022,'safe canonical user home required')
    base=home
    for part in ('.local','state','gb10sor'):
        base=base/part
        try:base.mkdir(mode=0o700)
        except FileExistsError:pass
        info=base.lstat()
        need(stat.S_ISDIR(info.st_mode) and base.resolve(strict=True)==base and info.st_uid==os.getuid() and
             not stat.S_IMODE(info.st_mode)&0o022,'unsafe existing bootstrap ancestor')
    result={}
    for name in ('private-evidence','direct-guards'):
        leaf=base/name
        try:leaf.mkdir(mode=0o700)
        except FileExistsError:pass
        info=leaf.lstat()
        need(stat.S_ISDIR(info.st_mode) and leaf.resolve(strict=True)==leaf and info.st_uid==os.getuid() and
             stat.S_IMODE(info.st_mode)==0o700,'existing private parent must already be owned0700')
        result[name]=str(leaf)
    return result


def tool_pin(name):
    need(name in ('iperf3','ib_write_bw','nix','timeout'),'unexpected package executable')
    found=shutil.which(name);need(found is not None,'enter the direct Nix shell for '+name)
    path=Path(found).resolve(strict=True)
    multicall=name=='timeout' and path.name=='coreutils'
    if multicall:
        original=Path(found)
        need(re.fullmatch('/nix/store/[a-z0-9]+-coreutils-[A-Za-z0-9._+-]+/bin/timeout',str(original)) and
             path==original.with_name('coreutils'),'timeout must be the same-store GNU coreutils alias')
    else:
        need(re.fullmatch('/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/'+name,str(path)),'benchmark outside immutable Nix store')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        need(stat.S_ISREG(info.st_mode) and info.st_uid==0 and not stat.S_IMODE(info.st_mode)&0o022 and
             stat.S_IMODE(info.st_mode)&0o111 and 0<info.st_size<=33554432,'unsafe benchmark executable')
        pin=hashlib.file_digest(stream,'sha256').hexdigest()
        stable=lambda s:(s.st_dev,s.st_ino,s.st_uid,s.st_gid,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
        need(stable(os.stat(path,follow_symlinks=False))==stable(info),'benchmark changed while sealing')
    result=dict(path=str(path),sha256=pin)
    if name=='timeout':result['argvPrefix']=[str(path),'--coreutils-prog=timeout'] if multicall else [str(path)]
    return result


def shell_benchmark_pins(value):
    """The direct Nix shell supplies tools; machine config does not invent paths."""
    result=copy.deepcopy(value)
    pins={key:tool_pin(name) for key,name in (('iperf','iperf3'),('perftest','ib_write_bw'))}
    for node in result['nodes']:node['link'].update(copy.deepcopy(pins))
    return result

def prepared_provision(path):
    """One strict private-input path for both plan-only and foreground run."""
    value=shell_benchmark_pins(json.loads(private(Path(path).resolve(strict=True))))
    return provision_check(value)

def publish(root,name,raw):
    need(Path(name).name==name,'local receipt basename')
    fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())
    fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def provision_check(value):
    base={'version','profile','tools','transport','nodes','linkSettings','budgets','environment'}
    need(PROFILE in DIRECT_PROFILES,'unreviewed direct model profile')
    need(set(value) in (base,base|{'networkLifecycle'}) and value['version']==1 and
         value['profile']==MACHINE_PROFILE,'reviewed direct machine provisioning schema')
    lifecycle=value.get('networkLifecycle','transient-switched')
    need(lifecycle in ('transient-switched','predeclared-direct'),'explicit network lifecycle')
    need(len(value['nodes'])==2 and [x['rank'] for x in value['nodes']]==[0,1],'ordered exact pair')
    need(set(value['tools'])=={'python','systemctl','systemdRun','hostname','bash'},'frontend tool inventory')
    for path in value['tools'].values():need(re.fullmatch('/nix/store/[A-Za-z0-9._/+:-]+',path),'pinned frontend tool')
    need(set(value['transport'])=={'ssh','identity','knownHosts','knownHostsSha256','pythonByRank'},'provisioned existing control identity')
    python_by_rank=value['transport']['pythonByRank']
    need(isinstance(python_by_rank,dict) and set(python_by_rank)=={'0','1'},'exact per-rank owned Python inventory')
    for node in value['nodes']:
        path=python_by_rank[str(node['rank'])]
        need(isinstance(path,str) and re.fullmatch(r'/nix/store/[A-Za-z0-9][A-Za-z0-9+._-]*/bin/python3(?:\.[0-9]+)*',path) and
             path==node['guard']['python']==node['link']['identity']['python'], 'per-rank owned Python identity mismatch')
    b=value['budgets']
    need(set(b)=={'serve','modelLease','parentRuntime','controllerRuntime','controllerStop','rollbackDelay','rollbackExecution','rollbackStop','localCleanup'},'finite budget schema')
    need(all(type(x)is int and x>0 for x in b.values()) and b['serve']<=3600 and b['modelLease']<=43200 and
         b['controllerStop']<=300 and b['rollbackStop']<=30 and 240<=b['localCleanup']<=1200 and b['rollbackExecution']<=3600 and
         b['rollbackExecution']>=2*b['localCleanup']+1200,'cleanup/finite serving budget')
    need(b['localCleanup']>=4*(value['linkSettings']['stopSeconds']+50)+540+180+170,'local cleanup bound omits helper stop/disarm/readback')
    need(b['controllerRuntime']>=b['parentRuntime']+2400+value['linkSettings']['leaseSeconds']+240 and
         b['rollbackDelay']>=b['controllerRuntime']+b['controllerStop']+b['rollbackExecution']+300 and b['rollbackDelay']<=86400,
         'original rollback does not enclose controller/parent/cleanup')
    need(isinstance(value['environment'],dict) and all(re.fullmatch('(?:DEUCES|GB10)_[A-Z0-9_]+',k) and isinstance(v,str) and '\0' not in v for k,v in value['environment'].items()),'provisioned engine environment')
    for side in ('LEFT','RIGHT'):
        path=value['environment'].get('DEUCES_'+side+'_MODEL_ROOT','')
        need(re.fullmatch('/[A-Za-z0-9._/-]+',path) and path!='/' and '..' not in Path(path).parts,'explicit local NVMe model root required')
    for node in value['nodes']:
        need(set(node)=={'rank','host','node','guardParent','guard','networkBefore','link'},'node provisioning schema')
        need(re.fullmatch('[A-Za-z0-9_.@:-]+',node['host']) and not node['host'].startswith('-'),'fixed node address')
        g=node['guard'];link=node['link']
        need(g['hostname']==node['node'] and g['rank']==node['rank'] and g['host']==node['host'] and
             link['host']==node['host'] and link['identity']['hostname']==node['node'] and
             link['identity']['systemClosure']==g['systemClosure'] and link['identity']['bootId']==g['bootId'], 'guard/link identity mismatch')
        need(g['directInterface']=='enp1s0f0np0' and link['rdmaDevice']=='mlx5_0' and link['perftest'] is not None,'one primary HCA plus mandatory RDMA')
        need(Path(node['guardParent']).is_absolute() and '..' not in Path(node['guardParent']).parts,'guard state parent')
        if lifecycle=='predeclared-direct':
            need(g.get('networkMode')=='deuces-direct' and type(g.get('dockerEnabled')) is bool and
                 g.get('hca')==link['rdmaDevice']=='mlx5_0' and
                 re.fullmatch('[A-Za-z0-9_.-]{1,128}',g.get('profileName','')) and
                 re.fullmatch('[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',g.get('profileUuid','')) and
                 type(g.get('directRouteMetric')) is int and 1<=g['directRouteMetric']<4294967295,
                 'sealed Nix-owned direct profile required')
            port=node['networkBefore'].get('interfaces',{}).get(g['directInterface'],{})
            link_state=node['networkBefore'].get('directLink')
            routes=[row for row in node['networkBefore'].get('routes4',[]) if row.get('dev')==g['directInterface'] and row.get('table','main') in ('main',254)]
            expected_link=dict(carrier='1',speedMbps=200000,fec=dict(configured='Auto',active='RS'),
                               hca=dict(device=g['hca'],port=1,state='ACTIVE',physicalState='LINK_UP',netdev=g['directInterface']))
            need(port.get('uuid')==g['profileUuid'] and port.get('addresses') and
                 link_state==expected_link and
                 len(routes)==1 and routes[0].get('metric')==g['directRouteMetric'],
                 'predeclared direct profile/link/route not exact in sealed baseline')
            need(node['networkBefore'].get('systemClosure')==g['systemClosure'] and
                 re.fullmatch('/nix/store/[a-z0-9]+-nixos-system-[A-Za-z0-9._+-]+',node['networkBefore'].get('persistentClosure','')),
                 'exact current and persistent closures required')
    need(value['nodes'][0]['host']!=value['nodes'][1]['host'] and value['nodes'][0]['node']!=value['nodes'][1]['node'],'distinct hosts')
    if lifecycle=='predeclared-direct':
        need(len({n['guard']['profileUuid'] for n in value['nodes']})==2,'predeclared direct UUIDs must be node-unique')
    return value


def plan(value,source,root,owner=None,frontend_process=None,link_only=False):
    """Local-only generation. No host queries, service or network changes."""
    need(type(link_only) is bool,'explicit internal qualification scope')
    provision_check(value);source=Path(source);root=Path(root)
    need(root.is_absolute() and root.is_dir() and root.resolve(strict=True)==root,'new canonical private proof root')
    need(stat.S_IMODE(root.stat().st_mode)==0o700 and root.stat().st_uid==os.getuid() and not list(root.iterdir()),'fresh empty private proof root')
    owner=os.urandom(32).hex() if owner is None else owner;need(re.fullmatch('[a-f0-9]{64}',owner),'fresh ownership token')
    snapshot=root/'source';snapshot.mkdir(mode=0o700)
    for directory in ('scripts','tests'):
        destination=snapshot/directory;destination.mkdir(mode=0o700)
        for path in sorted((source/directory).rglob('*')):
            if '__pycache__' in path.parts:continue
            need(not path.is_symlink(),'source snapshot refuses symlinks')
            relative=path.relative_to(source/directory);target=destination/relative
            if path.is_dir():target.mkdir(mode=0o700)
            elif path.is_file():shutil.copyfile(path,target);target.chmod(0o700 if path.suffix=='.sh' else 0o600)
            else:raise RuntimeError('source snapshot special file')
    shutil.copyfile(source/'model-profiles.json',snapshot/'model-profiles.json');(snapshot/'model-profiles.json').chmod(0o600)
    for name in ('flake.lock','overlays/edge-cuda.nix','overlays/edge-python.nix','packages/perftest-26.04.17.nix'):
        path=source/name;target=snapshot/name
        need(path.resolve(strict=True)==path and path.is_file(),'package source missing or linked')
        target.parent.mkdir(mode=0o700,exist_ok=True)
        shutil.copyfile(path,target);target.chmod(0o600)
    P=module(snapshot/'scripts/deuces-link-plan.py');I=module(snapshot/'scripts/deuces-direct-inventory.py');N=module(snapshot/'scripts/deuces-direct-network.py')
    inputs=dict(version=1,nodes=[copy.deepcopy(n['link']) for n in value['nodes']],settings=value['linkSettings'])
    link_plan=P.build(inputs,(snapshot/'scripts/deuces-link-server.py').read_bytes(),owner)
    publish(root,'link-plan.json',encoded(link_plan))
    b=value['budgets'];controller='gb10sor-direct-controller-'+owner[:32]+'.service'
    controller_argv=[value['tools']['python'],'-I','-B',str(snapshot/'scripts/deuces-direct-frontend.py'),'controller',str(root)]
    model_evidence=root/'model-evidence';parent=Path(str(model_evidence)+'.parent')
    run_id='gb10sor-direct-'+owner[:32]
    registry_raw=(snapshot/'model-profiles.json').read_bytes()
    expected=dict(maxModelLeaseSeconds=b['modelLease'],**I.recipe(registry_raw,PROFILE))
    RP=module(snapshot/'scripts/deuces-resource-parent.py')
    expected['sourceSha256']=RP.source_pins(expected['engine'])
    expected['nodes']=[dict(rank=n['rank'],host=n['host'],node=n['node'],systemClosure=n['guard']['systemClosure'],modelStateParent='/tmp') for n in value['nodes']]
    configs=[];files=[];targets=[]
    source_bytes={name:(snapshot/'scripts'/name).read_bytes() for name in GUARD_SOURCES}
    lifecycle=value.get('networkLifecycle','transient-switched')
    for node in value['nodes']:
        rank=node['rank'];g=copy.deepcopy(node['guard']);baseline=encoded(node['networkBefore'])
        state_root=node['guardParent']+'/gb10sor-direct-'+owner[:32]
        profile_uuid=g['profileUuid'] if lifecycle=='predeclared-direct' else str(uuid.uuid4())
        profile_name=g['profileName'] if lifecycle=='predeclared-direct' else run_id+('-left-a' if rank==0 else '-right-a')
        g.update(owner=owner,profileUuid=profile_uuid,profileName=profile_name,networkLifecycle=lifecycle,peerCidr=value['nodes'][1-rank]['guard']['cidr'],
            linkPlan=link_plan,inventoryExpected=expected,controlTransport=value['transport'],
            controller=dict(unit=controller,argv=controller_argv,runtimeSeconds=b['controllerRuntime'],stopSeconds=b['controllerStop']),
            modelParentState=str(parent),rollbackUnit='gb10sor-direct-rollback-'+owner[:30]+str(rank)+'0',rollbackDelaySeconds=b['rollbackDelay'],
            rollbackExecutionSeconds=b['rollbackExecution'],rollbackStopSeconds=b['rollbackStop'],localCleanupBudgetSeconds=b['localCleanup'],
            launchReserveSeconds=b['modelLease']+b['rollbackExecution']+60,
            ownedObserverUnits=[controller,'gb10sor-direct-finalizer-'+owner[:32]+'.service','gb10sor-direct-rollback-'+owner[:30]+str(rank)+'0.service'])
        if lifecycle=='predeclared-direct':g['persistentClosure']=node['networkBefore']['persistentClosure']
        g['frontendProcess']=frontend_process if rank==0 else None
        g['linkOnly']=link_only
        g['peerBootIds']={n['host']:n['guard']['bootId'] for n in value['nodes']}
        g['firewallRules']=N.parent_firewall_rules(g)
        g['sources']={name:sha(raw) for name,raw in source_bytes.items()};g['sources']['network-before.json']=sha(baseline)
        config_raw=encoded(g);config_sha=sha(config_raw)
        targets.append(dict(rank=rank,host=node['host'],node=node['node'],stateRoot=state_root,configSha256=config_sha));configs.append(g)
        files.append(dict(source_bytes,**{'network-before.json':baseline,'config.json':config_raw,'OWNER':(owner+'\n').encode()}))
    for rank in (0,1):files[rank]['pair-guard-configurations.json']=encoded(dict(owner=owner,configSha256=targets[rank]['configSha256'],peers=targets))
    replication=dict(version=1,guards=targets,transport=value['transport'],inventoryExpected=expected,
        sources={name:sha((snapshot/'scripts'/name).read_bytes()) for name in ('deuces-direct-inventory.py','deuces-owned-container.py','deuces-declaration-channel.py')})
    publish(root,'replication.json',encoded(replication))
    # Provisioning owns machine/network inputs. Model paths and image pins are
    # derived afresh from the selected, sealed registry profile by the child.
    # Legacy Laguna-specific values must not bleed into another model.
    inherited={k:v for k,v in value['environment'].items() if k not in {
        'DEUCES_LEFT_MODEL_DIR','DEUCES_RIGHT_MODEL_DIR',
        'DEUCES_LEFT_AUXILIARY_MODEL_DIR','DEUCES_RIGHT_AUXILIARY_MODEL_DIR',
        'DEUCES_LEFT_DRAFT_MODEL_DIR','DEUCES_RIGHT_DRAFT_MODEL_DIR',
        'DEUCES_VLLM_IMAGE','DEUCES_VLLM_EXPECTED_IMAGE_ID','DEUCES_VLLM_EXPECTED_LAYERS_SHA256',
        'DEUCES_SGLANG_IMAGE','DEUCES_SGLANG_EXPECTED_IMAGE_ID','DEUCES_SGLANG_EXPECTED_LAYERS_SHA256'
    }}
    environment=dict(inherited,GB10_MODEL_PROFILE=PROFILE,GB10_DEUCES_OWNED_LIFECYCLE='1',GB10_DEUCES_PARENT_FIREWALL='1',
        GB10_DEUCES_PRECONFIGURED_DIRECT='1' if lifecycle=='predeclared-direct' else '0',
        GB10_DEUCES_LINK_ONLY='1' if link_only else '0',
        GB10_DEUCES_NETWORK_OWNER=owner,GB10_DEUCES_FRONTEND_PROOF=str(root),GB10_DEUCES_FRONTEND_CHILD='1',
        GB10_DEUCES_PREDECLARED_RUN_ID=run_id,
        GB10_DEUCES_PARENT_RUNTIME_SECONDS=str(b['parentRuntime']),GB10_DEUCES_OWNED_LEASE_SECONDS=str(b['modelLease']),
        GB10_DEUCES_LOCAL_PYTHON=value['tools']['python'],DEUCES_SERVE_MAX_SECONDS=str(b['serve']),DEUCES_DIRECT_INTERFACE_COUNT='1',
        GB10_DEUCES_LEFT_OWNED_PYTHON=value['transport']['pythonByRank']['0'],
        GB10_DEUCES_RIGHT_OWNED_PYTHON=value['transport']['pythonByRank']['1'],
        DEUCES_LINK_SERVER_PLAN=str(root/'link-plan.json'),DEUCES_LINK_SERVER_PLAN_SHA256=sha(encoded(link_plan)),
        DEUCES_PAYLOAD_EVIDENCE_DIR=str(model_evidence),GB10_PRIVATE_EVIDENCE_ROOT=str(root),
        GB10_DEUCES_PRE_ACK_HELPER=str(snapshot/'scripts/deuces-direct-replicate.py'),GB10_DEUCES_PRE_ACK_HELPER_SHA256=sha((snapshot/'scripts/deuces-direct-replicate.py').read_bytes()),
        GB10_DEUCES_PRE_ACK_CONFIG=str(root/'replication.json'),GB10_DEUCES_PRE_ACK_CONFIG_SHA256=sha(encoded(replication)),
        DEUCES_SSH_IDENTITY_FILE=value['transport']['identity'],DEUCES_SSH_KNOWN_HOSTS_FILE=value['transport']['knownHosts'],
        DEUCES_IPERF_BIN=inputs['nodes'][0]['iperf']['path'],DEUCES_PERFTEST_BIN=inputs['nodes'][0]['perftest']['path'],
        DEUCES_IPERF_SECONDS=str(value['linkSettings']['iperfSeconds']),DEUCES_IPERF_STREAMS=str(value['linkSettings']['iperfStreams']),
        DEUCES_RDMA_SECONDS=str(value['linkSettings']['rdmaSeconds']))
    if PROFILE=='inkling-small-nvfp4-sglang-dspark':
        selected=json.loads(registry_raw)['profiles'][PROFILE]
        need(selected.get('imageId')=='7c88acadca1de22bcf20e19a3acb05a4878829aa706c1ea28a6a4988dfd3c1d3' and
             selected.get('rootfsLayersSha256')=='837b48467fb50caa766e356620f87ad536f1010f0224ce0c47e4e3c9d032a8ad',
             'Inkling local runtime identity changed')
        environment.update(
            DEUCES_SGLANG_IMAGE='localhost/gb10sor/inkling-sglang-gb10:qualified-direct-079775a8',
            DEUCES_SGLANG_EXPECTED_IMAGE_ID=selected['imageId'],
            DEUCES_SGLANG_EXPECTED_LAYERS_SHA256=selected['rootfsLayersSha256'])
    if PROFILE in {'qwen38-flash-next-direct-bounded','glm53-flash-nvfp4-sglang-dflash2','glm53-flash-nvfp4-sglang-target-only'}:
        selected=json.loads(registry_raw)['profiles'][PROFILE]
        need(isinstance(selected.get('imageId'),str) and len(selected['imageId'])==64 and
             isinstance(selected.get('rootfsLayersSha256'),str) and len(selected['rootfsLayersSha256'])==64,
             'SGLang direct runtime identity is incomplete')
        environment.update(
            # Local archive imports can re-encode a manifest while retaining
            # the immutable image configuration and every rootfs layer. Use
            # the reviewed local tag, but continue to enforce both identities.
            DEUCES_SGLANG_IMAGE=selected.get('localImage',selected['image']),
            DEUCES_SGLANG_EXPECTED_IMAGE_ID=selected['imageId'],
            DEUCES_SGLANG_EXPECTED_LAYERS_SHA256=selected['rootfsLayersSha256'])
    if PROFILE in {'qwen38-flash-next-nvidia-vllm','deepseek-v4-nvidia-anemll-vllm','deepseek-v4-flash-0731-nvidia-vllm','deepseek-v4-flash-0731-nvidia-v028','deepseek-v41-flash-exl3-29bpw'}:
        selected=json.loads(registry_raw)['profiles'][PROFILE]
        need(isinstance(selected.get('imageId'),str) and len(selected['imageId'])==64 and
             isinstance(selected.get('rootfsLayersSha256'),str) and len(selected['rootfsLayersSha256'])==64,
             'vLLM direct runtime identity is incomplete')
        environment.update(
            # A Podman archive import may re-encode the manifest while retaining
            # the immutable config/image ID and every rootfs layer.  Profiles
            # may therefore name the imported local tag; the child still
            # enforces both approved identity hashes below.
            DEUCES_VLLM_IMAGE=selected.get('localImage',selected['image']),
            DEUCES_VLLM_EXPECTED_IMAGE_ID=selected['imageId'],
            DEUCES_VLLM_EXPECTED_LAYERS_SHA256=selected['rootfsLayersSha256'],
            DEUCES_VLLM_ENFORCE_EAGER='0')
    for side,node,g in zip(('LEFT','RIGHT'),value['nodes'],configs):
        environment.update({f'DEUCES_{side}_HOST':node['host'],f'DEUCES_{side}_NODE':node['node'],f'DEUCES_{side}_RAIL_A':g['cidr'],
                            f'GB10_DEUCES_PREDECLARED_{side}_UUID':g['profileUuid'],f'GB10_DEUCES_PREDECLARED_{side}_NAME':g['profileName']})
        if lifecycle=='predeclared-direct':environment[f'GB10_DEUCES_PREDECLARED_{side}_ROUTE_METRIC']=str(g['directRouteMetric'])
    manifest={str(path.relative_to(snapshot)):sha(path.read_bytes()) for path in sorted(snapshot.rglob('*')) if path.is_file()}
    result=dict(version=1,owner=owner,targets=targets,configs=configs,provision=value,controller=controller,controllerArgv=controller_argv,
        runId=run_id,environment=environment,sourceManifest=manifest,linkPlanSha256=sha(encoded(link_plan)))
    publish(root,'plan.json',encoded(result))
    for rank in (0,1):publish(root,f'guard{rank}-stage.json',encoded({name:base64.b64encode(raw).decode() for name,raw in files[rank].items()}))
    return result


def load_plan(root):
    root=Path(root);value=json.loads(private(root/'plan.json'))
    for name,pin in value['sourceManifest'].items():
        path=root/'source'/name;need(path.resolve(strict=True)==path and path.is_file() and sha(path.read_bytes())==pin,'immutable source changed')
    need(sha(private(root/'link-plan.json'))==value['linkPlanSha256'],'internal link plan changed')
    return value


def local_state(root):
    value=load_plan(root);g=module(Path(root)/'source/scripts/deuces-direct-guard.py')
    state,modules=g.bootstrap(value['targets'][0]['stateRoot'],value['targets'][0]['configSha256'])
    g.identity(state.config)
    return value,state,modules


def controller(root):
    root=Path(root);value=load_plan(root);deadline=time.monotonic()+120
    while not (root/'controller-replicated.json').exists():
        need(time.monotonic()<deadline,'controller start replication was never completed')
        time.sleep(.1)
    gate=json.loads(private(root/'controller-replicated.json'))
    need(gate.get('owner')==value['owner'] and gate.get('targets')==value['targets'],'controller barrier changed')
    _,state,modules=local_state(root)
    need(not (state.root/'launch-closed.json').exists() and not (state.root/'recovery-started.json').exists(),'controller claim already closed')
    now=modules['deuces-direct-cleanup.py'].controller_properties(state,modules)
    saved=state.read('controller-executing.json')
    modules['deuces-direct-cleanup.py'].controller_policy(state,modules,now)
    need(now.get('MainPID')==str(os.getpid())==str(saved['pid']) and now.get('InvocationID')==saved['invocationId'],'controller actual unit/PID changed')
    for rank in (0,1):rpc(root,'enter-idle',rank,timeout=180)
    env=dict(os.environ,**value['environment'])
    # The source config was already resolved into the sealed provisioning plan.
    # Do not source an unsealed .env again inside this bounded controller.
    env['GB10_DEUCES_DIRECT_CONFIG']='/dev/null'
    argv=[value['provision']['tools']['bash'],str(root/'source/scripts/deuces-direct-model.sh'),'qualify-and-serve']
    child=subprocess.Popen(argv,cwd=str(root/'source'),env=env)
    interrupted=[]
    def marked(signum,frame):interrupted.append(signum)
    old={number:signal.signal(number,marked) for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP)}
    try:code=child.wait()
    finally:
        for number,handler in old.items():signal.signal(number,handler)
    publish(root,'controller-result.json',encoded(dict(owner=value['owner'],childExit=code,signals=interrupted)))
    return code if code>=0 else 128-code


def controller_show(root):
    _,state,modules=local_state(root)
    return modules['deuces-direct-cleanup.py'].controller_properties(state,modules)


def finalizer(root):
    value,state,modules=local_state(root)
    # This actor is not the controller it is about to prove terminal.
    saved=state.read('controller-executing.json');need(saved['pid']!=os.getpid(),'finalizer cannot execute inside controller')
    result=modules['deuces-direct-cleanup.py'].controller_terminal(state,modules,controller_show(root))
    g=module(Path(root)/'source/scripts/deuces-direct-guard.py')
    outcome=g.finalize(state,modules)
    for rank in (0,1):rpc(root,'lease-disarm',rank,timeout=45)
    publish(Path(root),'finalizer-result.json',encoded(dict(owner=value['owner'],controller=result,outcome=outcome)))
    return 0


def profiles_ready(root):
    for rank in (0,1):rpc(root,'direct-ready',rank,timeout=120)
    for rank in (0,1):rpc(root,'firewall-ready',rank,timeout=180)


def verify_child(root,plan_path,plan_sha,run_id):
    root=Path(root);value=load_plan(root)
    need(str(root/'link-plan.json')==plan_path and value['linkPlanSha256']==plan_sha and value['runId']==run_id,'child differs from fresh internal plan')
    receipt=json.loads(private(root/'links-prestaged.json'))
    need(receipt.get('owner')==value['owner'] and receipt.get('planSha256')==plan_sha and receipt.get('result',{}).get('result')=='pass','link staging not positive')
    gate=json.loads(private(root/'controller-replicated.json'))
    need(gate.get('owner')==value['owner'] and gate.get('targets')==value['targets'],'controller not acknowledged by both guards')
    for key,expected in value['environment'].items():
        need(os.environ.get(key)==expected,'child provisioning environment changed: '+key)
    _,state,modules=local_state(root)
    need(not (state.root/'launch-closed.json').exists() and not (state.root/'recovery-started.json').exists(),'closed frontend cannot be replayed')
    saved=state.read('controller-executing.json');current=controller_show(root)
    modules['deuces-direct-cleanup.py'].controller_policy(state,modules,current)
    need(current.get('ActiveState')=='active' and current.get('SubState')=='running' and
         current.get('InvocationID')==saved['invocationId'] and current.get('MainPID')==str(saved['pid']) and
         Path('/proc/self/cgroup').read_text().strip()=='0::'+saved['cgroup'],'child must execute inside exact current controller cgroup')
    return True


def unit_show(tools,unit,run=None):
    """Read missing-unit shape without converting a transport failure to absence."""
    args=[tools['systemctl'],'--user','show',unit]
    keys=('Id','LoadState','Description','InvocationID','ActiveState','SubState','MainPID','ControlGroup','Result','ExecMainPID','ExecMainCode','ExecMainStatus','Type','RemainAfterExit','Restart','KillMode','WorkingDirectory','ExecStart','TimeoutStartUSec','TimeoutStopUSec')
    args += [part for key in keys for part in ('-p',key)]
    reply=subprocess.run(args,cwd='/',capture_output=True,text=True,timeout=15) if run is None else run(args,timeout=15)
    need(reply.returncode in (0,4),'unit query failed')
    value=module(HERE/'deuces-direct-lease.py').properties(reply.stdout)
    need(value.get('Id')==unit and value.get('LoadState') in ('loaded','not-found'),'unit query identity')
    if value['LoadState']=='not-found':
        need(value.get('ActiveState')=='inactive' and value.get('SubState')=='dead' and value.get('MainPID')=='0','missing service state malformed')
    else:need(reply.returncode==0,'loaded unit query failed')
    return value


def finalizer_policy(value,unit,argv,owner,budgets):
    L=module(HERE/'deuces-direct-lease.py')
    need(value.get('Id')==unit and value.get('LoadState')=='loaded' and value.get('Description')==owner,'finalizer ownership')
    L.exact_exec(value.get('ExecStart',''),argv)
    for key,expected in dict(Type='oneshot',RemainAfterExit='yes',Restart='no',KillMode='control-group',WorkingDirectory='/').items():
        need(value.get(key)==expected,'finalizer execution policy changed: '+key)
    for key,seconds in (('TimeoutStartUSec',budgets['rollbackExecution']),('TimeoutStopUSec',budgets['rollbackStop'])):
        need(L.duration(value.get(key))==seconds*1000000,'finalizer execution bound changed')


def stop_terminal_metadata(root,unit,before,group,run=None):
    """Stop only positively terminal, recorded owned metadata after restoration."""
    run=command if run is None else run
    value,state,modules=local_state(root);tools=value['provision']['tools']
    need(before.get('MainPID')=='0' and before.get('Description')==value['owner'] and
         re.fullmatch('[0-9a-f]{32}',before.get('InvocationID','')) and group.endswith('/'+unit),'metadata stop identity')
    modules['deuces-direct-state.py'].cgroup_empty(group)
    current=unit_show(tools,unit)
    need(current==before,'unit changed before terminal metadata stop')
    publish(Path(root),unit+'.metadata-stop-intent.json',encoded(dict(owner=value['owner'],before=before,cgroup=group)))
    run([tools['systemctl'],'--user','stop',unit],timeout=20)
    after=unit_show(tools,unit)
    need(after.get('MainPID')=='0' and (after.get('ActiveState'),after.get('SubState')) in (('inactive','dead'),('failed','failed')),'metadata stop not terminal')
    if after['LoadState']=='loaded':
        need(after.get('Description')==value['owner'] and after.get('InvocationID') in ('',before['InvocationID']) and
             after.get('ExecStart')==before['ExecStart'],'metadata replaced during stop')
    modules['deuces-direct-state.py'].cgroup_empty(group)
    publish(Path(root),unit+'.metadata-stopped.json',encoded(dict(owner=value['owner'],before=before,after=after,cgroup=group,cgroupEmpty=True)))


def launch(root,run=None):
    """One bounded controller plus one independent finalizer; no GUI windows."""
    run=command if run is None else run
    root=Path(root);value=stage(root,run);p=value['provision'];b=p['budgets'];tools=p['tools']
    _,state,modules=local_state(root);C=modules['deuces-direct-cleanup.py']
    need(not (state.root/'launch-closed.json').exists(),'closed launch claim')
    argv=[tools['systemdRun'],'--user','--unit='+value['controller'],'--description='+value['owner'],
          '--property=Type=exec','--property=RemainAfterExit=yes','--property=Restart=no','--property=KillMode=control-group','--property=WorkingDirectory=/',
          '--property=RuntimeMaxSec='+str(b['controllerRuntime']),'--property=TimeoutStartSec=15','--property=TimeoutStopSec='+str(b['controllerStop']),
          '--setenv=PATH='+os.environ['PATH'],*value['controllerArgv']]
    # Unique immutable attempt, prior exact unit collision query and original
    # lease checks prevent a changed-source retry or budget renewal.
    existing=unit_show(tools,value['controller'])
    need(existing.get('LoadState')=='not-found','controller unit collision')
    publish(root,'controller-start-intent.json',encoded(dict(owner=value['owner'],argv=argv)))
    run(argv,timeout=20)
    now=controller_show(root);C.controller_policy(state,modules,now)
    need(now.get('ActiveState')=='active' and now.get('SubState')=='running' and int(now.get('MainPID','0'))>0,'controller did not start')
    packet=dict(version=1,owner=value['owner'],headGuard=value['targets'][0],properties=now)
    for rank in (0,1):rpc(root,'accept-controller-start',rank,packet,timeout=30)
    publish(root,'controller-replicated.json',encoded(dict(owner=value['owner'],targets=value['targets'],invocationId=now['InvocationID'])))
    requested=[]
    def signal_requested(signum,frame):requested.append(signum)
    old={number:signal.signal(number,signal_requested) for number in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP)}
    until=time.monotonic()+b['controllerRuntime']+b['controllerStop']+60;sent=False
    try:
        while True:
            current=controller_show(root)
            if current.get('MainPID')=='0':break
            need(current.get('InvocationID')==now['InvocationID'] and current.get('MainPID')==now['MainPID'],'controller identity changed during wait')
            if requested and not sent:
                C.controller_policy(state,modules,current)
                # Exact manager-owned control group, not PID-only termination.
                run([tools['systemctl'],'--user','kill','--kill-whom=all','--signal=SIGINT',value['controller']],timeout=15);sent=True
            need(time.monotonic()<until,'controller bound exhausted; keep independent rollback evidence')
            time.sleep(1)
    finally:
        for number,handler in old.items():signal.signal(number,handler)
    C.controller_terminal(state,modules,current)
    unit='gb10sor-direct-finalizer-'+value['owner'][:32]+'.service'
    need(unit_show(tools,unit).get('LoadState')=='not-found','finalizer unit collision')
    worker=[tools['python'],'-I','-B',str(root/'source/scripts/deuces-direct-frontend.py'),'finalizer',str(root)]
    args=[tools['systemdRun'],'--user','--no-block','--unit='+unit,'--description='+value['owner'],'--property=Type=oneshot','--property=RemainAfterExit=yes',
          '--property=Restart=no','--property=KillMode=control-group','--property=WorkingDirectory=/',
          '--property=TimeoutStartSec='+str(b['rollbackExecution']),'--property=TimeoutStopSec='+str(b['rollbackStop']),
          '--setenv=PATH='+os.environ['PATH'],*worker]
    publish(root,'finalizer-start-intent.json',encoded(dict(owner=value['owner'],argv=args)))
    run(args,timeout=20)
    ready_until=time.monotonic()+15
    while True:
        original=unit_show(tools,unit)
        if original.get('LoadState')=='loaded' and int(original.get('MainPID','0'))>0:break
        need(time.monotonic()<ready_until,'finalizer execution not observed before readiness bound');time.sleep(.1)
    finalizer_policy(original,unit,worker,value['owner'],b)
    need(original.get('ActiveState')=='activating' and original.get('SubState')=='start' and
         int(original.get('MainPID','0'))>0 and re.fullmatch('[0-9a-f]{32}',original.get('InvocationID','')) and
         original.get('ControlGroup','').startswith('/user.slice/') and original['ControlGroup'].endswith('/'+unit),'finalizer not observed executing')
    publish(root,'finalizer-executing.json',encoded(original))
    until=time.monotonic()+b['rollbackExecution']+b['rollbackStop']+30
    while True:
        final=unit_show(tools,unit);finalizer_policy(final,unit,worker,value['owner'],b)
        need(final.get('InvocationID')==original['InvocationID'],'finalizer invocation replaced')
        if final.get('MainPID')=='0':break
        need(time.monotonic()<until,'finalizer not positively complete; retain all guards/evidence')
        time.sleep(1)
    need(final.get('ActiveState')=='active' and final.get('SubState')=='exited' and final.get('Result')=='success' and
         final.get('ExecMainPID')==original['MainPID'] and final.get('ExecMainCode')=='1' and final.get('ExecMainStatus')=='0' and
         final.get('ControlGroup') in ('',original['ControlGroup']),'finalizer did not naturally complete')
    modules['deuces-direct-state.py'].cgroup_empty(original['ControlGroup'])
    result=json.loads(private(root/'finalizer-result.json'));need(result['owner']==value['owner'],'foreign finalizer completion')
    stop_terminal_metadata(root,unit,final,original['ControlGroup'],run)
    # Controller metadata must remain available until both guards have consumed
    # the terminal proof. Stop it only after finalizer success and both disarms.
    controller_final=unit_show(tools,value['controller'])
    C.controller_terminal(state,modules,controller_show(root))
    stop_terminal_metadata(root,value['controller'],controller_final,state.read('controller-executing.json')['cgroup'],run)
    preserved=value['provision'].get('networkLifecycle','transient-switched')=='predeclared-direct'
    outcome='predeclared direct baseline preservation' if preserved else 'switched baseline restoration'
    print('Finite direct run and '+outcome+' completed; private evidence: '+str(root),flush=True)
    return 130 if requested else int(current.get('ExecMainStatus','1'))


STAGE=r'''
import base64,hashlib,json,os,pathlib,stat,sys
root=pathlib.Path(sys.argv[1]);pin=sys.argv[2]
raw=sys.stdin.buffer.read(4194305)
if len(raw)>4194304:raise RuntimeError('stage packet exceeds bound')
packet=json.loads(raw);files={k:base64.b64decode(v,validate=True) for k,v in packet.items()}
if any(pathlib.Path(k).name!=k or len(v)>1048576 for k,v in files.items()):raise RuntimeError('stage filename/size')
if hashlib.sha256(files['config.json']).hexdigest()!=pin:raise RuntimeError('stage config seal')
cfg=json.loads(files['config.json'])
if files['OWNER']!=(cfg['owner']+'\n').encode():raise RuntimeError('stage owner')
persistent=cfg.get('persistentClosure',cfg['systemClosure']) if cfg.get('networkLifecycle','transient-switched')=='predeclared-direct' else cfg['systemClosure']
if pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=cfg['bootId'] or os.path.realpath('/run/current-system')!=cfg['systemClosure'] or os.path.realpath('/nix/var/nix/profiles/system')!=persistent:raise RuntimeError('stage host build/boot')
for nic,mac in cfg['macs'].items():
 if pathlib.Path('/sys/class/net',nic,'address').read_text().strip()!=mac:raise RuntimeError('stage physical identity')
for name,expected in cfg['sources'].items():
 if hashlib.sha256(files[name]).hexdigest()!=expected:raise RuntimeError('stage source seal')
parent=root.parent
home=pathlib.Path.home()
if parent!=home/'.local/state/gb10sor/direct-guards':raise RuntimeError('only fixed user direct-guards parent may be bootstrapped')
if home.resolve(strict=True)!=home or home.stat().st_uid!=os.getuid() or stat.S_IMODE(home.stat().st_mode)&0o022:raise RuntimeError('unsafe user home')
base=home
for part in ('.local','state','gb10sor'):
 base=base/part
 try:os.mkdir(base,0o700)
 except FileExistsError:pass
 info=base.lstat()
 if not stat.S_ISDIR(info.st_mode) or base.resolve(strict=True)!=base or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)&0o022:raise RuntimeError('unsafe bootstrap ancestor')
for name in ('private-evidence','direct-guards'):
 leaf=base/name
 try:os.mkdir(leaf,0o700)
 except FileExistsError:pass
 info=leaf.lstat()
 if not stat.S_ISDIR(info.st_mode) or leaf.resolve(strict=True)!=leaf or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o700:raise RuntimeError('unsafe private bootstrap leaf')
if not root.is_absolute() or '..' in root.parts or parent.resolve(strict=True)!=parent or parent.stat().st_uid!=os.getuid() or stat.S_IMODE(parent.stat().st_mode)!=0o700:raise RuntimeError('private preprovisioned stage parent')
os.mkdir(root,0o700)
for name,content in files.items():
 fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'wb') as f:f.write(content);f.flush();os.fsync(f.fileno())
fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY);os.fsync(fd);os.close(fd)
print(json.dumps({'result':'pass','root':str(root),'configSha256':pin,'files':{k:hashlib.sha256(v).hexdigest() for k,v in files.items()}}))
'''


def command(argv,timeout=20,input=None):
    result=subprocess.run(argv,cwd='/',capture_output=True,text=True,timeout=timeout,input=input)
    need(result.returncode==0,'bounded frontend command failed: '+repr(argv[:4])+': '+result.stderr[:2048])
    return result.stdout


def transport(plan,target,argv,timeout=20,input=None,run=command):
    t=plan['provision']['transport']
    # Do not read/print/hash the key. Validate existing ownership and modes;
    # exact known-host content is pinned and never learned on demand.
    for field,private_mode in (('identity',True),('knownHosts',False)):
        path=Path(t[field]);need(path.is_absolute() and path.resolve(strict=True)==path,'canonical SSH input')
        info=path.stat();need(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and not info.st_mode & (0o077 if private_mode else 0o022),'SSH input ownership/mode')
        if not private_mode:need(sha(path.read_bytes())==t['knownHostsSha256'],'known-host pins changed')
    need(re.fullmatch('/nix/store/[A-Za-z0-9._+-]+/bin/ssh',t['ssh']),'pinned SSH tool')
    remote=[t['ssh'],'-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5',
            '-o','ConnectionAttempts=1','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=1','-o','UserKnownHostsFile='+t['knownHosts'],
            '-i',t['identity'],target['host'],shlex.join(argv)]
    return run(remote,timeout=timeout,input=input)


def rpc(root,action,rank,packet=None,timeout=20,run=command):
    value=load_plan(root);target=value['targets'][rank];cfg=value['configs'][rank]
    argv=[cfg['python'],'-I','-B',target['stateRoot']+'/deuces-direct-guard.py',action,target['stateRoot'],target['configSha256']]
    # Local direct dispatch avoids self-SSH recursion for guard statuses. Link
    # helpers still use the reviewed transport, so its self+peer SSH directions
    # are separately tested before any lease/transition.
    raw=run(argv,timeout=timeout,input=None if packet is None else encoded(packet).decode()) if rank==0 else transport(value,target,argv,timeout,None if packet is None else encoded(packet).decode(),run)
    result=json.loads(raw)
    need(result.get('version')==1 and result.get('result')=='pass' and result.get('owner')==value['owner'] and
         result.get('guard')==target and result.get('action')==action,'guard response identity')
    return result


def stage(root,run=command,arm=True):
    need(type(arm) is bool,'explicit stage/arm boundary')
    root=Path(root);value=load_plan(root);tools=value['provision']['tools']
    need(run([tools['hostname'],'-s']).strip()==value['targets'][0]['node'],'literal command must run on provisioned head Spark')
    for target,cfg in zip(value['targets'],value['configs']):
        # Actual link transport directions, including self, must work before
        # f1 is disconnected. No key copying, new host pins or auth weakening.
        observed=transport(value,target,[cfg['python'],'-I','-B','-c','import socket;print(socket.gethostname())'],run=run).strip()
        need(observed==target['node'],'preflight control direction/hostname mismatch')
    for target,cfg in zip(value['targets'],value['configs']):
        raw=private(root/f'guard{target["rank"]}-stage.json').decode()
        argv=[cfg['python'],'-I','-B','-c',STAGE,target['stateRoot'],target['configSha256']]
        reply=run(argv,timeout=30,input=raw) if target['rank']==0 else transport(value,target,argv,30,raw,run)
        result=json.loads(reply)
        expected={k:sha(base64.b64decode(v)) for k,v in json.loads(raw).items()}
        need(result==dict(result='pass',root=target['stateRoot'],configSha256=target['configSha256'],files=expected),'remote stage readback differs')
        publish(root,f'guard{target["rank"]}-staged.json',encoded(result))
    for rank in (0,1):rpc(root,'preflight',rank,timeout=120,run=run)
    T=module(root/'source/scripts/deuces-link-server-transport.py');link=json.loads(private(root/'link-plan.json'))
    packages=module(root/'source/scripts/deuces-direct-tools.py');nix=tool_pin('nix')
    package_evidence=root/'package-realization';package_evidence.mkdir(mode=0o700)
    packages.ensure(value,root/'source',package_evidence,(root/'source/scripts/deuces-link-server.py').read_bytes(),T,
        lambda rank,argv,timeout:run(argv,timeout=timeout) if rank==0 else transport(value,value['targets'][rank],argv,timeout=timeout,run=run),
        lambda argv,timeout:run(argv,timeout=timeout),nix['path'],nix['sha256'],tool_pin('timeout'),T.publish,allow_build=arm)
    # Package-client cleanup must finish before the network/controller leases.
    # Re-read both full baselines after any Nix-store-only realization.
    for rank in (0,1):rpc(root,'preflight',rank,timeout=120,run=run)
    evidence=root/'link-prestage';evidence.mkdir(mode=0o700)
    result=T.batch(link,value['linkPlanSha256'],'stage-all',str(evidence),value['provision']['transport']['identity'],value['provision']['transport']['knownHosts'],
                   (root/'source/scripts/deuces-link-server.py').read_bytes())
    need(result.get('result')=='pass','link slot prestaging failed')
    publish(root,'links-prestaged.json',encoded(dict(owner=value['owner'],planSha256=value['linkPlanSha256'],result=result)))
    if not arm:return value
    for rank in (0,1):rpc(root,'lease-prepare',rank,run=run)
    for rank in (0,1):rpc(root,'lease-arm',rank,run=run)
    pair_status=[rpc(root,'lease-status',rank,run=run) for rank in (0,1)]
    packet=dict(version=1,owner=value['owner'],peers=pair_status)
    for rank in (0,1):rpc(root,'accept-pair-armed',rank,packet,timeout=30,run=run)
    publish(root,'pair-armed-replicated.json',encoded(packet))
    return value


def main():
    need(sys.flags.isolated and not sys.flags.optimize,'isolated Python required')
    need(len(sys.argv)>=3,'explicit frontend action required')
    action=sys.argv[1]
    if action=='plan':
        need(len(sys.argv)==4,'plan requires provisioning and new proof directory')
        value=prepared_provision(sys.argv[2]);plan(value,HERE.parent,Path(sys.argv[3]).resolve(strict=True));return 0
    if action=='verify-child':
        need(len(sys.argv)==6,'child proof arguments');verify_child(sys.argv[2],*sys.argv[3:]);return 0
    if action in ('controller','finalizer','profiles-ready'):
        need(len(sys.argv)==3,'owned internal action arguments');return {'controller':controller,'finalizer':finalizer,'profiles-ready':profiles_ready}[action](Path(sys.argv[2])) or 0
    need(action=='run' and len(sys.argv)==3,'unknown frontend action')
    provision=prepared_provision(sys.argv[2])
    parents=bootstrap_parents(Path.home())
    base=Path(os.environ.get('GB10_PRIVATE_EVIDENCE_ROOT',parents['private-evidence']))
    need(base.is_absolute() and base.resolve(strict=True)==base and base.is_dir() and stat.S_IMODE(base.stat().st_mode)==0o700,'private provisioned evidence parent required')
    root=base/('deuces-direct-'+os.urandom(16).hex());root.mkdir(mode=0o700)
    # Only this exact foreground observer may coexist with the GPU-idle
    # preflight. Its PID reuse/start/argv/executable are rechecked by snapshots.
    pid=os.getpid();proc=Path('/proc')/str(pid)
    frontend_process=dict(pid=pid,uid=os.getuid(),startTicks=proc.joinpath('stat').read_text().split(') ',1)[1].split()[19],
                          argv=proc.joinpath('cmdline').read_bytes().decode().split('\0')[:-1],executable=os.path.realpath(proc/'exe'))
    plan(provision,HERE.parent,root,frontend_process=frontend_process)
    return launch(root)


if __name__=='__main__':sys.exit(main())
