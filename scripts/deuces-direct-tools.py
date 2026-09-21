"""Pre-network package realization, reusing the qualified finite client helper.

No network configuration, trust-policy changes or unsigned closure imports.
Nix daemon jobs are not claimed as exclusively ours: cleanup proves only the
owned Nix client and its service descendants; shared daemon builds may remain
if another authorized client is interested in the same derivation.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat


def need(ok,why):
    if not ok:raise RuntimeError(why)

def encoded(value):return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()
def sha(raw):return hashlib.sha256(raw).hexdigest()
def nix_string(value):return json.dumps(value).replace('${','\\${')

def source_bytes(root,name):
    root=Path(root);path=root/name
    need(path.resolve(strict=True)==path,'source symlink')
    with os.fdopen(os.open(path,os.O_RDONLY|os.O_NOFOLLOW),'rb') as stream:
        info=os.fstat(stream.fileno())
        need(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and not info.st_mode&0o022 and info.st_size<=1048576,'unsafe package input')
        return stream.read(1048577)

def expression(root,key):
    need(key in ('iperf','perftest'),'unknown mandatory benchmark')
    lock=json.loads(source_bytes(root,'flake.lock'));nodes=lock['nodes']
    control_name=nodes[lock['root']]['inputs'].get('nixpkgs-control')
    need(isinstance(control_name,str) and control_name in nodes,'review root control nixpkgs changed')
    nixpkgs=nodes[control_name]
    def tree(node):
        pin=node['locked'];required=('type','owner','repo','rev','narHash')
        need(pin['type']=='github' and re.fullmatch('[a-f0-9]{40}',pin['rev']) and pin['narHash'].startswith('sha256-'),'unlocked package input')
        return 'builtins.fetchTree {'+''.join(k+'='+nix_string(pin[k])+';' for k in required)+'}'
    body='p.iperf3' if key=='iperf' else 'p.callPackage (builtins.toFile "gb10sor-perftest-26.04.17.nix" '+nix_string(source_bytes(root,'packages/perftest-26.04.17.nix').decode())+') {}'
    # The Deuces-direct shell intentionally uses nixpkgs-control, without the
    # CUDA/Python overlays. Reconstruct that exact package set here so the
    # evaluated output must match the executables selected by `nix develop`.
    return 'let np='+tree(nixpkgs)+'; p=import np.outPath {system="aarch64-linux";config={allowUnfree=true;allowUnsupportedSystem=true;};};in '+body


# This diagnostic never executes a benchmark workload. Absence is distinct
# from a permission/query/hash/version failure. The Nix path must be canonical.
PROBE=r'''import hashlib,json,os,stat,subprocess,sys
from pathlib import Path
path,expected=sys.argv[1:];p=Path(path)
def need(ok):
 if not ok:raise RuntimeError('package binary identity refused')
try:info=p.lstat()
except FileNotFoundError:
 print(json.dumps({'present':False}));sys.exit(0)
need(p.resolve(strict=True)==p and stat.S_ISREG(info.st_mode) and info.st_uid==0 and not info.st_mode&0o022 and info.st_mode&0o111 and 0<info.st_size<=33554432)
with os.fdopen(os.open(p,os.O_RDONLY|os.O_NOFOLLOW),'rb') as f:
 opened=os.fstat(f.fileno());digest=hashlib.file_digest(f,'sha256').hexdigest()
need((opened.st_dev,opened.st_ino,opened.st_size,opened.st_mtime_ns)==(info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns) and digest==expected)
r=subprocess.run([path,'--version'],cwd='/',capture_output=True,text=True,timeout=10)
need(len(r.stdout)+len(r.stderr)<=65536)
print(json.dumps({'present':True,'sha256':digest,'version':{'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}}))
'''

def timeout_prefix(pin):
    need(isinstance(pin,dict) and set(pin)=={'path','sha256','argvPrefix'} and re.fullmatch('[a-f0-9]{64}',pin['sha256']),
         'pinned evaluation timeout required')
    path=pin['path']
    if re.fullmatch('/nix/store/[a-z0-9]{32}-coreutils-[A-Za-z0-9._+-]+/bin/coreutils',path):expected=[path,'--coreutils-prog=timeout']
    else:
        need(re.fullmatch('/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+/bin/timeout',path),'unexpected timeout executable')
        expected=[path]
    need(pin['argvPrefix']==expected,'timeout multicall prefix changed')
    return expected


def evaluated(expr,nix,prefix,call):
    wrapped='let p=('+expr+'); in {drv=p.drvPath;out=p.outPath;file=builtins.toFile "gb10sor-direct-package.nix" '+nix_string(expr)+';}'
    # GNU timeout owns its finite process group. If SSH disappears, evaluation
    # still ends after 100s TERM +15s KILL; no network lease exists yet.
    raw=call([*prefix,'--signal=TERM','--kill-after=15','100',nix,'--extra-experimental-features','nix-command flakes','eval','--impure','--json','--expr',wrapped],125)
    value=json.loads(raw)
    need(set(value)=={'drv','out','file'} and all(isinstance(x,str) and re.fullmatch('/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+',x) for x in value.values()),'invalid package evaluation')
    need(value['drv'].endswith('.drv') and value['file'].endswith('.nix'),'package derivation/expression shape')
    return value


def binary_identity(value,key,node):
    need(set(value)=={'present','sha256','version'} and value['present'] is True,'incomplete binary proof')
    v=copy.deepcopy(value['version']);need(set(v)=={'exit','stdout','stderr'},'version diagnostic schema')
    if key=='iperf':
        lines=v['stdout'].splitlines(keepends=True)
        need(len(lines)==3 and lines[0].startswith('iperf ') and lines[1].startswith('Linux '+node+' ') and
             lines[2].startswith('Optional features available:') and v['exit']==0,'iperf version/host shape')
        # iperf prints uname(), including the node name. Only that exact
        # declared token is normalized; full raw diagnostics remain archived.
        lines[1]='Linux <node> '+lines[1][len('Linux '+node+' '):];v['stdout']=''.join(lines)
    elif key=='perftest':
        need(v==dict(exit=1,stdout='Version: 6.29\n',stderr=''),'pinned perftest diagnostic changed')
    else:raise RuntimeError('unknown binary diagnostic')
    return dict(sha256=value['sha256'],version=v)


def realize_slot(plan,slot,helper,evidence,transport,dispatch,publish):
    """All attempts recorded before writes; stop even on lost start replies."""
    seal=sha(encoded(plan));T=transport;started=False;failure=None;cleanup=None
    def action(name):
        return dispatch(plan,seal,name,slot['host'],slot['label'],str(evidence),T['identity'],T['knownHosts'],worker=helper if name=='stage' else None)
    try:
        started=True
        action('stage');action('prepare');action('start');action('wait-success')
    except BaseException as exc:
        failure=exc
    finally:
        if started:
            try:
                action('journal')
            except Exception as exc:publish(evidence,'package-journal-error.json',dict(error=str(exc)))
            try:
                action('stop');need(action('inspect') is None,'package client not stopped');cleanup=True
            except BaseException as exc:
                cleanup=False;publish(evidence,'package-cleanup-error.json',dict(error=str(exc)))
    publish(evidence,'package-result.json',dict(result='pass' if failure is None and cleanup else 'failed',cleanup=cleanup,error=None if failure is None else str(failure)))
    if failure is not None:raise failure
    need(cleanup is True,'package cleanup uncertain; no network lease permitted')


def ensure(plan,source,evidence,helper,T,call,local,nix,nix_sha,timeout_pin,publish,allow_build=True):
    """Sequential per-node package checks/builds before ANY network lease.

    call(rank, argv, timeout) is pinned existing head→node transport; local
    is the same checked runner on the head. No worker needs a private key.
    """
    need(type(allow_build) is bool,'explicit package build authority')
    source=Path(source);evidence=Path(evidence);result=[]
    for name in ('flake.lock','overlays/edge-cuda.nix','overlays/edge-python.nix','packages/perftest-26.04.17.nix'):
        need(sha(source_bytes(source,name))==plan['sourceManifest'].get(name),'sealed package source changed')
    need(re.fullmatch('/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+/bin/nix',nix) and re.fullmatch('[a-f0-9]{64}',nix_sha),'pinned Nix client required')
    prefix=timeout_prefix(timeout_pin)
    for rank,node in enumerate(plan['provision']['nodes']):
        proof=json.loads(call(rank,[node['guard']['python'],'-I','-B','-c',PROBE,timeout_pin['path'],timeout_pin['sha256']],20))
        need(proof.get('present') is True,'bounded evaluation tool unavailable')
        publish(evidence,f'evaluation-timeout-{rank}.json',proof)
    for key in ('iperf','perftest'):
        expr=expression(source,key);head=evaluated(expr,nix,prefix,local)
        publish(evidence,key+'-head-evaluation.json',dict(expressionSha256=sha(expr.encode()),evaluation=head))
        pin=plan['provision']['nodes'][0]['link'][key]
        need(str(Path(pin['path']).parent.parent)==head['out'],'head shell tool differs from sealed recipe')
        reference=json.loads(local([plan['provision']['tools']['python'],'-I','-B','-c',PROBE,pin['path'],pin['sha256']],20))
        need(reference.get('present') is True,'head shell tool absent')
        for rank,node in enumerate(plan['provision']['nodes']):
            py=node['guard']['python'];binary=node['link'][key]
            need(binary==pin,'pair tool mismatch')
            probe=lambda:json.loads(call(rank,[py,'-I','-B','-c',PROBE,binary['path'],binary['sha256']],20))
            before=probe();publish(evidence,f'{key}-{rank}-before.json',before)
            if before.get('present') is False:
                need(allow_build,'stage-only requires realized tool; no package service authorized')
                # Check actual Nix executable bytes even though no version
                # comparison is needed between an installed Nix and perftest.
                nix_probe=json.loads(call(rank,[py,'-I','-B','-c',PROBE,nix,nix_sha],20));need(nix_probe.get('present') is True,'worker pinned Nix unavailable')
                worker=evaluated(expr,nix,prefix,lambda argv,timeout:call(rank,argv,timeout))
                publish(evidence,f'{key}-{rank}-evaluation.json',worker)
                need(worker==head,'worker derivation/input/output mismatch')
                token=sha((plan['owner']+key+str(rank)).encode())[:32]
                root=node['guardParent']+'/gb10sor-link-server.'+token
                cfg=dict(version=2,owner=plan['owner'],hostname=node['node'],bootId=node['guard']['bootId'],systemClosure=node['guard']['systemClosure'],
                    python=py,tools=node['link']['identity']['tools'],unit=Path(root).name+'.service',workerSha256=sha(helper),binarySha256=nix_sha,
                    argv=[nix,'--extra-experimental-features','nix-command','--extra-experimental-features','flakes','build','--no-link','--max-jobs','1','--cores','2','--option','timeout','600','--option','max-silent-time','120','--impure','--file',worker['file']],
                    leaseSeconds=900,stopSeconds=30,memlock=dict(mode='inherit'))
                # Repeat the additive option so the already proved helper
                # need not accept whitespace-bearing argv fields.
                slot=dict(host=node['host'],label='package-'+key+'-'+str(rank),state=root,config=cfg,configSha256=sha(encoded(cfg)))
                owned=dict(version=1,owner=plan['owner'],helperSha256=sha(helper),slots=[slot]);T.validate(owned)
                directory=evidence/slot['label'];directory.mkdir(mode=0o700)
                publish(directory,'package-plan.json',owned)
                realize_slot(owned,slot,helper,directory,plan['provision']['transport'],T.dispatch,T.publish)
            after=probe();publish(evidence,f'{key}-{rank}-after.json',after)
            need(binary_identity(after,key,node['node'])==binary_identity(reference,key,plan['provision']['nodes'][0]['node']),
                 'worker binary/version tuple mismatch')
            result.append(dict(key=key,rank=rank,result='pass',built=before.get('present') is False))
    publish(evidence,'result.json',dict(result='pass',checks=result))
    return result
