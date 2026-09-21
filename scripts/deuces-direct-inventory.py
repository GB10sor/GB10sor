"""Validate the engine's pre-write resource inventory for both local guards.

Only metadata bytes are examined. No paths in model mounts are traversed, no
resources are started, and an acknowledgement is not a cleanup receipt.
"""
import hashlib
import json
from pathlib import Path
import re


def require(ok,why):
    if not ok:raise RuntimeError(why)


def digest(raw):return hashlib.sha256(raw).hexdigest()


DIRECT_PROFILES = {
    'laguna-s21-nvfp4',
    'qwen38-flash-next-direct-bounded',
    'qwen38-flash-next-nvidia-vllm',
    'deepseek-v4-sglang-target-only',
    'deepseek-v4-nvidia-anemll-vllm',
    'deepseek-v4-flash-0731-nvidia-vllm',
    'deepseek-v4-flash-0731-nvidia-v028',
    'deepseek-v41-flash-exl3-29bpw',
    'inkling-small-nvfp4-sglang-dspark',
    'glm53-flash-nvfp4-sglang-dflash2',
    'glm53-flash-nvfp4-sglang-target-only',
}


def recipe(registry_raw, recipe_id):
    """Derive exact target/auxiliary/draft slots from the sealed registry."""
    value=json.loads(registry_raw)
    require(value.get('schemaVersion')==1,'recipe registry schema')
    require(recipe_id in DIRECT_PROFILES,'unreviewed direct recipe')
    profile=value.get('profiles',{}).get(recipe_id)
    require(isinstance(profile,dict) and profile.get('engine') in ('vllm','sglang') and
            isinstance(profile.get('modelId'),str),'direct recipe identity')
    hash_slots={f'target-rank{rank}':profile.get('weightTreeSha256') for rank in (0,1)}
    if profile.get('auxiliaryModel') is not None:
        aux=profile['auxiliaryModel']
        require(isinstance(aux,dict) and aux.get('modelId') and
                aux.get('containerPath') in ('/draft-model','/engram-src'),
                'unexpected auxiliary recipe role')
        rank_contracts=aux.get('rankContracts')
        if rank_contracts is None:
            for rank in (0,1):hash_slots[f'auxiliary-rank{rank}']=aux.get('weightTreeSha256')
        else:
            require(isinstance(rank_contracts,dict),'auxiliary rank contracts')
            for rank in (0,1):
                contract=rank_contracts.get(f'rank{rank}')
                require(isinstance(contract,dict),'auxiliary rank contract')
                hash_slots[f'auxiliary-rank{rank}']=contract.get('weightTreeSha256')
    if profile.get('speculative') is not None:
        draft=profile['speculative']
        require(isinstance(draft,dict) and draft.get('modelId'),'unexpected draft recipe role')
        for rank in (0,1):hash_slots[f'draft-rank{rank}']=draft.get('weightTreeSha256')
    require(all(isinstance(v,str) and re.fullmatch('[0-9a-f]{64}',v) for v in hash_slots.values()),'recipe tree pins')
    return dict(recipeId=recipe_id,engine=profile['engine'],recipeRegistrySha256=digest(registry_raw),
                hashSlots=hash_slots)


def laguna_recipe(registry_raw):
    """Compatibility helper retained for existing fixtures and receipts."""
    result=recipe(registry_raw,'laguna-s21-nvfp4')
    result.pop('engine')
    return result


def validate(packet, expected, container_validator):
    require(set(packet)=={'version','declaration','declarationSha256','configs'} and packet['version']==1,'inventory packet schema')
    require(isinstance(packet['declaration'],str) and len(packet['declaration'].encode())<=1048576,'bounded declaration text')
    raw=packet['declaration'].encode()
    require(digest(raw)==packet['declarationSha256'],'inventory declaration changed')
    def pairs(values):
        result={}
        for k,v in values:
            require(k not in result,'duplicate inventory JSON key');result[k]=v
        return result
    decl=json.loads(raw,object_pairs_hook=pairs)
    require(set(decl)=={'schemaVersion','kind','invocationOwner','runId','engine','sourceSha256','containers','hashes'},'exact declaration schema')
    require(decl['schemaVersion']==1 and decl['kind']=='gb10sor.deuces.resource-declaration','declaration version')
    require(decl['engine']==expected['engine'] and decl['sourceSha256']==expected['sourceSha256'],'engine source pin mismatch')
    require(re.fullmatch('[0-9a-f]{64}',decl['invocationOwner']) and re.fullmatch('gb10sor-'+decl['engine']+'-[A-Za-z0-9-]+',decl['runId']),'declaration owner/run')
    require(isinstance(decl['containers'],list) and len(decl['containers'])==2 and
            {x.get('rank') for x in decl['containers']}=={0,1},'two container ranks required')
    require(isinstance(packet['configs'],list) and len(packet['configs'])==2 and
            {x.get('rank') for x in packet['configs']}=={0,1},'two config bytes required')
    configs=[]
    for item in sorted(decl['containers'],key=lambda x:x['rank']):
        rank=item['rank']; node=next(x for x in expected['nodes'] if x['rank']==rank)
        require(set(item)=={'rank','host','node','configSha256','stateRoot'} and all(item[k]==node[k] for k in ('rank','host','node')),'container node identity')
        state=Path(item['stateRoot'])
        require(state.is_absolute() and '..' not in state.parts and str(state.parent)==node['modelStateParent'],'container root outside provisioned state parent')
        entry=next(x for x in packet['configs'] if x['rank']==rank)
        require(set(entry)=={'rank','text'} and isinstance(entry['text'],str) and len(entry['text'].encode())<=1048576,'config byte schema')
        require(digest(entry['text'].encode())==item['configSha256'],'container config bytes changed')
        cfg=json.loads(entry['text'],object_pairs_hook=pairs)
        container_validator(cfg,state)
        require(cfg['rank']==rank and cfg['hostname']==node['node'] and cfg['systemClosure']==node['systemClosure'] and
                cfg['owner']==decl['invocationOwner'] and cfg['sources']=={'worker.py':decl['sourceSha256']['containerHelper']},'config owner/closure/source mismatch')
        require(cfg['name']==decl['runId']+'-rank'+str(rank),'container name not bound to run')
        require(cfg['leaseSeconds']<=expected['maxModelLeaseSeconds'],'model lease exceeds outer envelope')
        configs.append(cfg)
    hashes=decl['hashes'];pins=expected['hashSlots']
    require(expected['recipeId'] in DIRECT_PROFILES and decl['engine'] in ('vllm','sglang') and
            re.fullmatch('[a-f0-9]{64}',expected['recipeRegistrySha256']) and isinstance(pins,dict) and
            {'target-rank0','target-rank1'} <= set(pins) and
            set(pins) <= {f'{role}-rank{rank}' for role in ('target','auxiliary','draft') for rank in (0,1)},
            'exact direct recipe slot inventory required')
    require(all(isinstance(v,str) and re.fullmatch('[a-f0-9]{64}',v) for v in pins.values()) and
            all(pins[role+'-rank0']==pins[role+'-rank1'] for role in ('target','auxiliary','draft')
                if role+'-rank0' in pins), 'recipe pair tree pins differ')
    require(isinstance(hashes,list) and len(hashes)==len(pins) and
            {x.get('slot') for x in hashes}==set(pins),'exact direct hash slots required')
    require(len({x.get('stateRoot') for x in hashes})==len(hashes) and len({x.get('unit') for x in hashes})==len(hashes),'hash state/unit collision')
    for item in hashes:
        require(set(item)=={'slot','rank','host','stateRoot','unit','token','helperSha256','expectedTreeSha256'},'hash declaration schema')
        rank=item['rank'];require(type(rank) is int and rank in (0,1),'hash rank')
        node=next(x for x in expected['nodes'] if x['rank']==rank)
        require(item['host']==node['host'] and re.fullmatch('(target|auxiliary|draft)-rank'+str(rank),item['slot']),'hash host/slot mismatch')
        require(re.fullmatch('gb10sor-vllm-[A-Za-z0-9-]+-weights-rank'+str(rank),item['unit']),'hash unit identity')
        require(item['stateRoot']=='/tmp/'+item['unit'],'hash root not exact unit state')
        require(all(isinstance(item[k],str) and re.fullmatch('[0-9a-f]{64}',item[k]) for k in ('token','helperSha256','expectedTreeSha256')),'hash pins')
        require(item['helperSha256']==decl['sourceSha256']['hashHelper'],'hash helper source mismatch')
        require(item['expectedTreeSha256']==pins[item['slot']],'hash tree differs from sealed recipe')
    return dict(declaration=decl,configs=configs,declarationSha256=packet['declarationSha256'])
