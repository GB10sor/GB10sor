"""Pinned pre-ACK callback: duplicate metadata to both already-armed guards.

No model resources, profile writes, host-key discovery, key copies or retries.
The fixed receiver owns its private immutable inventory; failure on either node
refuses the parent ACK and leaves the independent guards armed.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time


def require(ok,why):
    if not ok:raise RuntimeError(why)


def raw_file(path,private=True,source=False):
    path=Path(path)
    require(path.is_absolute() and path.resolve(strict=True)==path,'canonical callback input')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as f:
        s=os.fstat(f.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_size<=1048576,'bounded callback regular input')
        permitted_owner=s.st_uid==os.getuid() or (source and str(path).startswith('/nix/store/') and s.st_uid==0)
        require(permitted_owner,'callback input owner')
        require(not s.st_mode & (0o077 if private else 0o022),'callback input permissions')
        raw=f.read(1048577);require(len(raw)<=1048576,'callback input grew');return raw


def digest(raw):return hashlib.sha256(raw).hexdigest()


def load(path,name):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def execute(channel,evidence,config,seal,run=subprocess.run,clock=time.monotonic):
    rawcfg=raw_file(config);require(digest(rawcfg)==seal,'replication config changed')
    cfg=json.loads(rawcfg)
    require(set(cfg)=={'version','guards','transport','inventoryExpected','sources'} and cfg['version']==1,'replication config schema')
    here=Path(__file__).resolve().parent
    require(set(cfg['sources'])=={'deuces-direct-inventory.py','deuces-owned-container.py','deuces-declaration-channel.py'},'replication source set')
    for name,pin in cfg['sources'].items():require(digest(raw_file(here/name,private=False,source=True))==pin,'replication source changed: '+name)
    C=load(here/'deuces-declaration-channel.py','replication_channel')
    I=load(here/'deuces-direct-inventory.py','replication_inventory')
    H=load(here/'deuces-owned-container.py','replication_container')
    raw=C.read(channel,'offered.json');anchor=C.check(channel,raw)
    packet=dict(version=1,declaration=raw.decode(),declarationSha256=digest(raw),configs=[])
    for rank in (0,1):
        value=raw_file(Path(evidence)/f'owned/rank{rank}-config.json')
        packet['configs'].append(dict(rank=rank,text=value.decode()))
    I.validate(packet,cfg['inventoryExpected'],H.validate_config)
    transport=cfg['transport']
    require(set(transport)=={'ssh','identity','knownHosts','knownHostsSha256','pythonByRank'},'replication transport schema')
    require(re.fullmatch('/nix/store/[A-Za-z0-9._+-]+/bin/ssh',transport['ssh']),'immutable SSH executable path')
    # Validate the existing private key without logging, copying or hashing it.
    # Match the established transport's no-group/other-access boundary.
    raw_file(transport['identity'])
    require(digest(raw_file(transport['knownHosts'],private=False))==transport['knownHostsSha256'],'trusted host pins changed')
    require(set(transport['pythonByRank'])=={'0','1'} and all(re.fullmatch('/nix/store/[A-Za-z0-9._+/-]+',p) for p in transport['pythonByRank'].values()),'pinned peer Python paths')
    require(len(cfg['guards'])==2 and {g['rank'] for g in cfg['guards']}=={0,1},'two guard targets required')
    deadline=clock()+50
    results=[]
    for guard in sorted(cfg['guards'],key=lambda x:x['rank']):
        require(set(guard)=={'rank','host','node','stateRoot','configSha256'},'guard target schema')
        require(re.fullmatch('[A-Za-z0-9_.@:-]+',guard['host']) and not guard['host'].startswith('-'),'fixed SSH host')
        root=Path(guard['stateRoot']);require(root.is_absolute() and '..' not in root.parts and str(root)!='/', 'guard state root')
        require(re.fullmatch('[0-9a-f]{64}',guard['configSha256']),'guard config digest')
        node=next(n for n in cfg['inventoryExpected']['nodes'] if n['rank']==guard['rank'])
        require(guard['host']==node['host'] and guard['node']==node['node'],'guard rank/node pair mismatch')
        command=[transport['pythonByRank'][str(guard['rank'])],'-I','-B',str(root/'deuces-direct-guard.py'),'accept-inventory',str(root),guard['configSha256']]
        argv=[transport['ssh'],'-T','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5','-o','ConnectionAttempts=1',
              '-o','ServerAliveInterval=5','-o','ServerAliveCountMax=1','-o','UserKnownHostsFile='+transport['knownHosts'],'-i',transport['identity'],guard['host'],shlex.join(command)]
        remaining=deadline-clock();require(remaining>0,'replication deadline exhausted')
        reply=run(argv,input=C.encoded(packet),capture_output=True,timeout=min(20,remaining),cwd='/')
        require(reply.returncode==0 and len(reply.stdout)<=1048576 and len(reply.stderr)<=65536,'guard replication failed; no retry or ACK')
        receipt=json.loads(reply.stdout,object_pairs_hook=C.pairs)
        require(set(receipt)=={'version','result','declaration','guard','inventorySha256','receiptSha256'} and
                receipt['version']==1 and receipt['result']=='pass' and receipt['declaration']==anchor and receipt['guard']==guard,'guard replication receipt mismatch')
        require(receipt['inventorySha256']==digest(C.encoded(packet)) and re.fullmatch('[0-9a-f]{64}',receipt['receiptSha256']),'guard inventory byte receipt mismatch')
        results.append(dict(guard,inventorySha256=receipt['inventorySha256'],receiptSha256=receipt['receiptSha256']))
    require(clock()<deadline and raw_file(config)==rawcfg and C.read(channel,'offered.json')==raw,'replication source/declaration drift or deadline')
    return dict(version=1,result='pass',declaration=anchor,guards=results)


if __name__=='__main__':
    require(sys.flags.isolated and not sys.flags.optimize,'Python -I required')
    require(len(sys.argv)==5,'channel evidence config config-sha required')
    print(json.dumps(execute(*sys.argv[1:]),sort_keys=True))
