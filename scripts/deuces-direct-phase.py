"""Pure selected-state checks for one-port direct entry and exact restoration.

All observations are produced by the separately sealed local snapshot worker.
No mutations, subprocesses, policy repair or model inspection in this module.
"""
import ipaddress
import copy
import json
import shlex


def require(ok, why):
    if not ok: raise RuntimeError(why)


def ordered(values):
    return sorted(values, key=lambda value: json.dumps(value, sort_keys=True))


def service_idle(value):
    return (value.get('LoadState') in ('loaded', 'not-found') and
            value.get('ActiveState') == 'inactive' and value.get('SubState') == 'dead' and
            value.get('MainPID') == '0')


def validate_original(original, cfg):
    """Reject an unexpected entry state before arming or writing anything."""
    predeclared=cfg.get('networkLifecycle','transient-switched')=='predeclared-direct'
    require(set(original['workloads']) == {'podman', 'rootPodman', 'docker', 'gpu', 'benchmarks'}, 'complete workload inventory required')
    require(isinstance(original['processInventory'],list) and isinstance(original['sessionInventory'],list) and
            set(original['activeServiceInventory'])=={'system','user'},'full process/session/service inventory required')
    require(all(isinstance(x, list) and not x for x in original['workloads'].values()), 'original workloads not empty')
    require(service_idle(original['services']['ray-cluster.service']), 'original Ray not idle')
    direct_idle=original['services']['cluster-direct-idle.service']
    require(direct_idle.get('LoadState')=='loaded' and direct_idle.get('ActiveState')=='active' and
            direct_idle.get('SubState')=='exited' and direct_idle.get('MainPID')=='0','original direct-idle service not active/exited')
    fabric=original['services']['cluster-fabric-profile.service']
    if predeclared:require(service_idle(fabric),'fabric service active in predeclared direct baseline')
    else:
        require(fabric.get('LoadState')=='loaded' and fabric.get('ActiveState')=='active' and
                fabric.get('SubState')=='exited' and fabric.get('MainPID')=='0','original fabric service not active/exited')
    if predeclared:
        direct=original['interfaces'][cfg['directInterface']];sibling=original['interfaces'][cfg['siblingInterface']]
        interface=ipaddress.ip_interface(cfg['cidr'])
        address=dict(family='inet',local=str(interface.ip),prefixlen=interface.network.prefixlen,scope='global')
        require(direct['addresses']==[address] and direct['uuid']==cfg['profileUuid'] and direct['autoconnect']=='no' and
                direct['mtu']==cfg['mtu'] and direct['arp']==['1','2'] and direct['adminUp'] is True,
                'predeclared direct profile not exact active baseline')
        require(sibling['addresses']==[] and sibling['uuid']=='' and sibling['autoconnect']=='no' and
                sibling['mtu']==1500 and sibling['arp']==['1','2'] and sibling['adminUp'] is True,
                'predeclared direct sibling not reviewed idle baseline')
        own=cfg['profileName']+':'+cfg['profileUuid']+':802-3-ethernet'
        require(original['profileInventory'].count(own)==1,'predeclared direct profile inventory mismatch')
        expected_link=dict(carrier='1',speedMbps=200000,fec=dict(configured='Auto',active='RS'),
                           hca=dict(device=cfg['hca'],port=1,state='ACTIVE',physicalState='LINK_UP',netdev=cfg['directInterface']))
        require(original.get('directLink')==expected_link,
                'predeclared direct carrier/speed/FEC baseline not exact')
        docker=original.get('dockerPolicy',{})
        require(set(docker)=={'enabled','units'} and docker['enabled'] is cfg['dockerEnabled'],
                'predeclared sealed Docker policy mismatch')
        if cfg['dockerEnabled']:require(docker['units'] is None,'enabled Docker policy has unit fallback')
        else:
            require(isinstance(docker['units'],dict) and set(docker['units'])=={'docker.service','docker.socket'},
                    'disabled Docker unit inventory mismatch')
            for name,value in docker['units'].items():
                expected={'Id','LoadState','ActiveState','SubState'}|({'MainPID'} if name.endswith('.service') else set())
                require(set(value)==expected and value['Id']==name and
                        value['LoadState'] in ('loaded','not-found') and value['ActiveState']=='inactive' and
                        value['SubState']=='dead' and (not name.endswith('.service') or value['MainPID']=='0'),
                        'disabled Docker unit baseline active/unknown')
        main=[row for row in original['routes4'] if row.get('dev')==cfg['directInterface'] and row.get('table','main') in ('main',254)]
        require(len(main)==1 and main[0].get('metric')==cfg['directRouteMetric'],
                'predeclared direct connected route metric not exact')
        for nic in cfg['switchInterfaces']:
            state=original['interfaces'][nic]
            require(state['adminUp'] is False and state['addresses']==[] and state['uuid']=='' and state['autoconnect']=='no',
                    'predeclared switch interface not idle')
            for family in ('4','6'):require(not [r for r in original['routes'+family] if r.get('dev')==nic],'predeclared switch route remains')
        return True
    for nic in (cfg['directInterface'], cfg['siblingInterface']):
        state = original['interfaces'][nic]
        require(state['addresses'] == [] and state['uuid'] == '' and state['autoconnect'] == 'no' and
                state['mtu'] == 1500 and state['arp'] == ['0', '0'] and state['adminUp'] is True, 'original direct port not reviewed idle state')
        require(not [r for r in original['routes4'] if r.get('dev') == nic], 'original direct IPv4 route')
        for row in [r for r in original['routes6'] if r.get('dev') == nic]:
            require(row.get('dst') == 'ff00::/8' and row.get('type') == 'multicast' and
                    row.get('table') in ('local', 255) and row.get('protocol') == 'kernel' and 'gateway' not in row,
                    'unexpected original direct IPv6 route')
    for nic in cfg['switchInterfaces']:
        state = original['interfaces'][nic]
        require(state['adminUp'] is True and state['mtu'] == 9000 and state['arp'] == ['1', '2'] and
                state['autoconnect'] == 'yes' and state['uuid'] and len(state['addresses']) == 1 and
                state['addresses'][0]['family'] == 'inet', 'original switch state not reviewed baseline')
    require(not any(cfg['profileUuid'] in line for line in original['profileInventory']), 'owned UUID already exists at baseline')
    return True


def validate_snapshot(current, original, cfg, phase):
    require(phase in ('switched', 'idle', 'direct-or-idle'), 'unknown network phase')
    predeclared=cfg.get('networkLifecycle','transient-switched')=='predeclared-direct'
    validate_original(original, cfg)
    for key in ('hostname', 'serial', 'bootId', 'systemClosure', 'persistentClosure', 'macs', 'unitDefinitions', 'switchSettings'):
        require(current[key] == original[key], 'identity/persistent state drift: ' + key)
    persistent=cfg.get('persistentClosure',cfg['systemClosure']) if predeclared else cfg['systemClosure']
    require(current['hostname'] == cfg['hostname'] and current['bootId'] == cfg['bootId'] and
            current['systemClosure'] == cfg['systemClosure'] and current['persistentClosure'] == persistent, 'configured identity mismatch')
    if predeclared:require(current.get('dockerPolicy')==original['dockerPolicy'],'predeclared Docker policy observation drift')
    direct, sibling = cfg['directInterface'], cfg['siblingInterface']
    switched = cfg['switchInterfaces']
    require(direct == 'enp1s0f0np0' and sibling == 'enP2p1s0f0np0' and
            switched == ['enp1s0f1np1', 'enP2p1s0f1np1'], 'one-port interface contract')
    selected = [direct, sibling, *switched]
    require(current['interfaces'][cfg['managementInterface']] == original['interfaces'][cfg['managementInterface']], 'management interface drift')
    for family in ('4', '6'):
        external = lambda state: ordered([x for x in state['routes' + family] if x.get('dev') not in selected])
        require(external(current) == external(original), 'external all-table route drift')
        require(current['rules' + family] == original['rules' + family], 'policy routing drift')
    profiles = list(current['profileInventory'])
    own = cfg['profileName'] + ':' + cfg['profileUuid'] + ':802-3-ethernet'
    require(profiles.count(own) <= 1, 'duplicate owned profile')
    if phase == 'direct-or-idle' and own in profiles and not predeclared: profiles.remove(own)
    require(ordered(profiles) == ordered(original['profileInventory']), 'unrelated NM profile change')
    require(service_idle(current['services']['ray-cluster.service']), 'Ray active/unknown')
    require(set(current['workloads']) == set(original['workloads']), 'missing workload query')
    for key, value in current['workloads'].items():
        require(isinstance(value, list) and value == [], 'workloads remain: ' + key)
    require(isinstance(current['processInventory'],list) and isinstance(current['sessionInventory'],list) and
            set(current['activeServiceInventory'])=={'system','user'},'full live inventory missing')
    allowed_user=set(cfg.get('ownedObserverUnits',[]))
    require(all(isinstance(x,str) and x.startswith('gb10sor-direct-') and x.endswith('.service') for x in allowed_user),'observer unit scope')
    for scope in ('system','user'):
        ignore={'cluster-fabric-profile.service'} if scope=='system' else allowed_user
        stable=lambda snap:ordered([x for x in snap['activeServiceInventory'][scope] if x['unit'] not in ignore])
        require(stable(current)==stable(original),'unrelated active service inventory drift')
    for family in ('4', '6'):
        allowed = cfg['firewallRules'] if family == '4' and phase == 'direct-or-idle' else []
        seen = set(); cleaned = []
        for line in current['firewall' + family]:
            argv = shlex.split(line)
            if argv in allowed:
                key = tuple(argv); require(key not in seen, 'duplicate owned firewall rule')
                seen.add(key)
            else: cleaned.append(line)
        require(cleaned == original['firewall' + family], 'unowned firewall drift')
        before_tables=original['firewallTables'+family];now_tables=current['firewallTables'+family]
        require(isinstance(before_tables,dict) and set(now_tables)==set(before_tables) and 'filter' in before_tables,
                'firewall table inventory changed/missing')
        require(before_tables['filter']==original['firewall'+family] and now_tables['filter']==current['firewall'+family],
                'filter aliases inconsistent')
        for table in before_tables:
            if table!='filter':require(now_tables[table]==before_tables[table],'unowned '+table+' firewall drift')
    if phase == 'switched':
        require(not predeclared,'predeclared direct cannot validate as switched')
        for nic in selected: require(current['interfaces'][nic] == original['interfaces'][nic], 'original NIC state not restored')
        for family in ('4','6'): require(ordered(current['routes'+family]) == ordered(original['routes'+family]), 'original all-table routes not restored')
        require(current['services'] == original['services'], 'original services not restored')
        return True
    require(service_idle(current['services']['cluster-fabric-profile.service']), 'fabric service not idle')
    require(current['services']['cluster-direct-idle.service'] == original['services']['cluster-direct-idle.service'], 'direct-idle service drift')
    for nic in switched:
        before, now = original['interfaces'][nic], current['interfaces'][nic]
        require(now['addresses'] == [] and not now['adminUp'] and now['uuid'] == '', 'switched interface not fully idle')
        for key in ('mac', 'mtu', 'arp', 'autoconnect'):
            require(now[key] == before[key], 'unexpected switch idle mutation')
        for family in ('4', '6'):
            require(not [x for x in current['routes'+family] if x.get('dev') == nic], 'non-main or IPv6 switch route remains')
    if phase == 'idle':
        require(not predeclared,'predeclared direct cannot validate as idle')
        for nic in (direct, sibling): require(current['interfaces'][nic] == original['interfaces'][nic], 'direct interface not original idle')
        for family in ('4', '6'):
            rows = lambda state: ordered([x for x in state['routes'+family] if x.get('dev') in (direct,sibling)])
            require(rows(current) == rows(original), 'direct idle routes changed')
        return True
    # During a fallback the exact owned profile may be active or already gone;
    # only its own address/kernel routes and both sibling ARP guards are allowed.
    for nic in (direct,sibling):
        now, before = current['interfaces'][nic], original['interfaces'][nic]
        require(now['mac'] == before['mac'] and now['autoconnect'] == 'no' and now['arp'] in (before['arp'], ['1','2']), 'direct interface identity/ARP/autoconnect drift')
        if nic == sibling:
            require(now['mtu'] == before['mtu'] and now['adminUp'] == before['adminUp'] and now['addresses'] == [] and now['uuid'] == '', 'second traffic rail or sibling mutation')
        else:
            require(now['adminUp'] == before['adminUp'] and now['mtu'] in (before['mtu'], cfg['mtu']) and now['uuid'] in ('', cfg['profileUuid']), 'foreign direct profile/MTU/admin state')
            expected = dict(family='inet', local=str(ipaddress.ip_interface(cfg['cidr']).ip), prefixlen=ipaddress.ip_interface(cfg['cidr']).network.prefixlen, scope='global')
            require(now['addresses'] == [] or now['addresses'] == [expected], 'foreign direct address/IPv6')
            require(not now['addresses'] or now['uuid'] == cfg['profileUuid'], 'address without owned profile')
        original6 = ordered([x for x in original['routes6'] if x.get('dev') == nic])
        now6 = ordered([x for x in current['routes6'] if x.get('dev') == nic])
        require(now6 == [] or now6 == original6, 'new direct IPv6 route')
        for row in [x for x in current['routes4'] if x.get('dev') == nic]:
            require(nic == direct and now['addresses'] and row.get('protocol') == 'kernel' and 'gateway' not in row, 'unexpected direct route')
            interface = ipaddress.ip_interface(cfg['cidr']); network = interface.network
            table = row.get('table', 'main')
            if table in ('main',254):
                require(row.get('dst') == str(network) and row.get('prefsrc') == str(interface.ip) and row.get('scope') == 'link', 'connected route mismatch')
            else:
                require(table in ('local',255) and ((row.get('type') == 'local' and row.get('dst') == str(interface.ip)) or
                        (row.get('type') == 'broadcast' and row.get('dst') in (str(network.network_address), str(network.broadcast_address)))), 'foreign non-main route')
    if predeclared:
        port=current['interfaces'][direct]
        require(port['uuid']==cfg['profileUuid'] and port['addresses'] and
                current.get('directLink')==original['directLink'],'predeclared direct profile/link became inactive or drifted')
        main=[row for row in current['routes4'] if row.get('dev')==direct and row.get('table','main') in ('main',254)]
        require(len(main)==1 and main[0].get('metric')==cfg['directRouteMetric'],
                'predeclared direct connected route metric drift')
        for family in ('4','6'):
            selected_rows=lambda state:ordered([row for row in state['routes'+family] if row.get('dev') in (direct,sibling)])
            require(selected_rows(current)==selected_rows(original),'predeclared direct selected route drift')
    return True


def validate_entry_partial(current, original, cfg, attempted):
    """Only recorded switch-to-idle actions can explain a partial entry.

    ``attempted`` has already been checked against immutable exact-argv intents
    by Network. No direct profile may have been started in this phase. A unit
    ExecStop that disconnects interfaces requires an explicit reviewed list;
    the default permits a service stop only, not inferred NIC side effects.
    """
    require(isinstance(attempted,set) and 'fabric-stop' in attempted, 'missing exact fabric-stop intent')
    switched=cfg['switchInterfaces']
    allowed={'fabric-stop'}|{'switch-'+action+'-'+nic for nic in switched for action in ('disconnect','admin-down')}
    require(attempted<=allowed,'unknown transition intent')
    effects=cfg.get('fabricStopDisconnects',[])
    require(isinstance(effects,list) and len(set(effects))==len(effects) and set(effects)<=set(switched), 'unreviewed fabric stop side effects')
    service=current['services']['cluster-fabric-profile.service']
    require(service==original['services']['cluster-fabric-profile.service'] or
            (service_idle(service) and service['LoadState']=='loaded'), 'partial fabric service state unsafe')
    normalized=copy.deepcopy(current)
    for nic in switched:
        now,before=current['interfaces'][nic],original['interfaces'][nic]
        permit_disconnect=nic in effects or 'switch-disconnect-'+nic in attempted
        permit_down='switch-admin-down-'+nic in attempted
        require(set(now)==set(before),'partial NIC observation missing/extra fields')
        for field in ('mac','mtu','arp','autoconnect'):
            require(now[field]==before[field],'partial transition changed '+field)
        if not permit_disconnect:
            require(now['uuid']==before['uuid'] and now['addresses']==before['addresses'],'disconnect without exact intent')
        else:
            require((now['uuid'],now['addresses']) in ((before['uuid'],before['addresses']),('',[])), 'partial foreign UUID/address')
        require(now['adminUp']==before['adminUp'] or (permit_down and now['adminUp'] is False),'admin change without exact intent')
        if not now['adminUp']:require(now['uuid']=='' and now['addresses']==[],'down interface retains address/profile')
        for family in ('4','6'):
            old=ordered([r for r in original['routes'+family] if r.get('dev')==nic])
            new=ordered([r for r in current['routes'+family] if r.get('dev')==nic])
            # Only the exact old routes or their removal is attributable to
            # disconnect; never accept different metrics, new routes or IPv6.
            require(new==old or (permit_disconnect and new==[]),'partial unowned route change')
            normalized['routes'+family]=[r for r in normalized['routes'+family] if r.get('dev')!=nic]+old
        normalized['interfaces'][nic]=copy.deepcopy(before)
    normalized['services']['cluster-fabric-profile.service']=copy.deepcopy(original['services']['cluster-fabric-profile.service'])
    # Reuse all strict unrelated-state, workload, firewall and original f0
    # assertions. Normalizing f1 here is validation only, never host repair.
    return validate_snapshot(normalized,original,cfg,'switched')
