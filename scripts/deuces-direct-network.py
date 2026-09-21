"""Concrete two-layer network actions, adapted from the reviewed outer.

Outer owns switched profile transition/restoration. The wrapper owns the normal
temporary direct profile, or observes an explicit sealed Nix-owned direct
baseline without changing its profile/interface state. Fallback requires the sealed cleanup bridge's
positive BOTH-node resource/controller proof before touching that profile.
No dynamic shell command strings, network-wide rules or broad cleanup.
"""
import json
from pathlib import Path
import re
import subprocess
import ipaddress
import copy
import hashlib
import os
import stat
import time

SW='/run/current-system/sw/bin/'
SUDO='/run/wrappers/bin/sudo'


def dispatcher_fingerprint():
    """Small read-only pin of the system-owned dispatcher and all hook roots."""
    unit=command([SW+'systemctl','cat','NetworkManager-dispatcher.service'],timeout=5)
    require(unit.strip(),'empty dispatcher definition')
    nm=Path(os.path.realpath(SW+'nmcli'))
    require(str(nm).startswith('/nix/store/') and nm.name=='nmcli' and nm.parent.name=='bin','dispatcher package identity')
    roots=[Path('/etc/NetworkManager/dispatcher.d'),Path('/run/NetworkManager/dispatcher.d'),
           Path('/usr/lib/NetworkManager/dispatcher.d'),nm.parent.parent/'lib/NetworkManager/dispatcher.d']
    records={};total=0
    for root in roots:
        if not root.exists():
            require(not root.is_symlink(),'dangling dispatcher hook root')
            records[str(root)]=None;continue
        resolved=root.resolve(strict=True);require(resolved.is_dir(),'dispatcher hook root not directory')
        entries=[]
        for path in [root,*sorted(resolved.rglob('*'))]:
            require(len(entries)<128,'dispatcher hook inventory bound')
            info=path.lstat();actual=path.resolve(strict=True);target=actual.stat()
            require(info.st_uid==0 and not (path!=root and stat.S_ISLNK(info.st_mode) and actual.is_dir()),'untracked dispatcher directory symlink')
            require(target.st_uid==0 and not target.st_mode&0o022,'dispatcher hook writable/nonroot')
            require(stat.S_ISDIR(target.st_mode) or stat.S_ISREG(target.st_mode),'special dispatcher hook')
            row=dict(path=str(path),resolved=str(actual),uid=target.st_uid,gid=target.st_gid,mode=stat.S_IMODE(target.st_mode),
                     link=os.readlink(path) if stat.S_ISLNK(info.st_mode) else None)
            if actual.is_file():
                require(target.st_size<=1048576,'dispatcher hook file bound');total+=target.st_size
                require(total<=4194304,'dispatcher hooks total bound')
                row['sha256']=hashlib.sha256(actual.read_bytes()).hexdigest()
            entries.append(row)
        records[str(root)]=entries
    return dict(unitSha256=hashlib.sha256(unit.encode()).hexdigest(),hooks=records)


def require(ok,why):
    if not ok:raise RuntimeError(why)


def command(argv,timeout=35):
    value=subprocess.run(argv,timeout=timeout,cwd='/',text=True,capture_output=True)
    require(value.returncode==0,'network action failed: '+repr(argv)+': '+value.stderr[:2048])
    return value.stdout


def parent_firewall_rules(cfg):
    peer=ipaddress.ip_interface(cfg['peerCidr']);local=ipaddress.ip_interface(cfg['cidr'])
    require(peer.version==4 and local.version==4 and peer.network==local.network and peer.ip!=local.ip and
            local.network.prefixlen==30 and cfg['directInterface']=='enp1s0f0np0' and
            re.fullmatch('[a-f0-9]{64}',cfg['owner']),'parent firewall exact one-port peer policy')
    common=['-A','nixos-fw','-s',str(peer.ip)+'/32','-i',cfg['directInterface'],'-p','tcp']
    link=[*common,'-m','tcp','--dport','5211:5324','-m','comment','--comment','gb10sor-direct-link-'+cfg['owner'],'-j','nixos-fw-accept']
    model=[*common,'-m','comment','--comment','gb10sor-direct-model-'+cfg['owner'],'-j','nixos-fw-accept']
    return [link,model]


class Network:
    def __init__(self,state,modules,run=command):
        self.state=state;self.cfg=state.config;self.modules=modules;self.run=run
        self.P=modules['deuces-direct-phase.py'];self.S=modules['deuces-direct-snapshot.py']
        self.original=json.loads(modules['deuces-direct-state.py'].read_file(state.root/'network-before.json'))
        require(modules['deuces-direct-state.py'].digest(modules['deuces-direct-state.py'].read_file(state.root/'network-before.json'))==self.cfg['sources']['network-before.json'],'original snapshot seal changed')
        self.P.validate_original(self.original,self.cfg)
        self.predeclared=self.cfg.get('networkLifecycle','transient-switched')=='predeclared-direct'
        if not self.predeclared:
            require(set(self.cfg['switchMetrics'])==set(self.cfg['switchInterfaces']) and
                    all(type(v) is int and 1<=v<=65535 for v in self.cfg['switchMetrics'].values()),'exact saved live switch metrics required')
            for nic in self.cfg['switchInterfaces']:
                rows=[r for r in self.original['routes4'] if r.get('dev')==nic and r.get('table','main') in ('main',254)]
                require(len(rows)==1 and rows[0].get('metric')==self.cfg['switchMetrics'][nic],'metric not derived from exact original route')

    def snapshot(self):
        self.state.sources()
        return self.S.collect(self.cfg)

    def check(self,phase):
        value=self.snapshot();self.P.validate_snapshot(value,self.original,self.cfg,phase);return value

    def preflight(self):
        phase='direct-or-idle' if self.predeclared else 'switched'
        value=self.check(phase)
        if self.predeclared:
            fields=self.run([SW+'nmcli','-g','connection.id,connection.interface-name,connection.autoconnect,ipv4.method,ipv4.addresses,ipv4.route-metric,ipv4.never-default,ipv6.method,802-3-ethernet.mtu','connection','show','uuid',self.cfg['profileUuid']]).splitlines()
            require(fields==[self.cfg['profileName'],self.cfg['directInterface'],'no','manual',self.cfg['cidr'],str(self.cfg['directRouteMetric']),'yes','disabled',str(self.cfg['mtu'])],
                    'predeclared direct profile configuration drift')
        return value

    def predeclared_final(self,value):
        """A terminal predeclared receipt never permits run-owned rule residue."""
        require(self.predeclared,'predeclared final-state check in switched lifecycle')
        for family in ('4','6'):
            require(value['firewall'+family]==self.original['firewall'+family] and
                    value['firewallTables'+family]==self.original['firewallTables'+family],
                    'predeclared final firewall differs from exact baseline')
        return value

    def check_settled(self,phase,clock=time.monotonic,sleep=time.sleep,attempted=None):
        """Retry only the known dispatcher transient, never other drift."""
        expected=self.state.read('dispatcher-before.json')['fingerprint']
        deadline=clock()+30;observations=[]
        def validate(value):
            if phase=='entry-partial':self.P.validate_entry_partial(value,self.original,self.cfg,attempted)
            else:self.P.validate_snapshot(value,self.original,self.cfg,phase)
        while True:
            require(clock()<deadline,'dispatcher did not settle within30s')
            require(dispatcher_fingerprint()==expected,'dispatcher definition/hooks changed')
            remaining=deadline-clock();require(remaining>0,'dispatcher did not settle within30s')
            value=self.S.collect(self.cfg,run=self.S.Query(max(1,min(30,int(remaining)))))
            try:validate(value)
            except RuntimeError:
                modified=copy.deepcopy(value)
                before=self.original['activeServiceInventory']['system']
                require(not any(x['unit']=='NetworkManager-dispatcher.service' for x in before),'dispatcher baseline was not inactive')
                transient=[x for x in value['activeServiceInventory']['system'] if x['unit']=='NetworkManager-dispatcher.service']
                require(len(transient)==1 and transient[0]['load']=='loaded' and
                        (transient[0]['active'],transient[0]['sub']) in (('active','running'),('activating','start'),('deactivating','stop')),
                        'phase mismatch is not a known dispatcher transient')
                modified['activeServiceInventory']['system']=[x for x in modified['activeServiceInventory']['system'] if x['unit']!='NetworkManager-dispatcher.service']
                validate(modified)
                observations.append(dict(elapsedSeconds=30-max(0,deadline-clock()),service=transient[0]))
                require(clock()<deadline,'dispatcher did not settle within30s');sleep(min(1,max(0,deadline-clock())))
                continue
            require(clock()<=deadline and dispatcher_fingerprint()==expected,'dispatcher settling bound/fingerprint changed')
            self.state.write('dispatcher-settled-'+phase+'.json',observations=observations,fingerprint=expected)
            return value

    def mutate(self,label,argv):
        # Immutable intent is durable before dispatch. Any lost reply consumes
        # the action; there is no changed-source retry or generic suppression.
        self.state.sources();self.state.intent(label,argv)
        reply=self.run(argv,timeout=35)
        self.state.write(label+'-done.json',argv=argv,stdout=reply[:65536])

    def enter_idle(self):
        with self.state.lock():
            before=self.preflight()
            # The controller verifies both real leases, then distributes its
            # per-node acknowledgement. This is not a source-only boolean.
            bridge=self.modules['deuces-direct-cleanup.py']
            bridge.verify_pair_armed(self.state,self.modules)
            self.modules['deuces-direct-lease.py'].Lease(self.state).check(self.cfg['launchReserveSeconds'])
            if self.predeclared:
                self.state.write('phase-idle.json',phase='predeclared-direct',snapshot=before)
                return before
            self.state.write('dispatcher-before.json',fingerprint=dispatcher_fingerprint())
            self.state.write('phase-transition-started.json',phase='switch-to-idle')
            self.mutate('fabric-stop',[SUDO,'-n',SW+'systemctl','stop','cluster-fabric-profile.service'])
            for nic in self.cfg['switchInterfaces']:
                # A reviewed ExecStop may already disconnect the exact UUID.
                # Query success and exact identity distinguish that state from
                # a failed connection-down command; no `|| true` fallback.
                uuid=self.run([SW+'nmcli','-g','GENERAL.CON-UUID','device','show',nic]).strip()
                require(uuid in ('','--',self.cfg['switchUuids'][nic]),'foreign switch UUID after profile stop')
                if uuid==self.cfg['switchUuids'][nic]:
                    self.mutate('switch-disconnect-'+nic,[SUDO,'-n',SW+'nmcli','--wait','10','connection','down','uuid',uuid])
                self.mutate('switch-admin-down-'+nic,[SUDO,'-n',SW+'ip','link','set',nic,'down'])
            after=self.check_settled('idle')
            self.state.write('phase-idle.json',phase='idle',snapshot=after)
            return after

    def remove_firewall(self):
        for index,rule in enumerate(self.cfg['firewallRules']):
            require(rule[:2]==['-A','nixos-fw'],'only declared filter-chain rules')
            # Current full snapshot already excludes arbitrary/duplicate rules.
            current=self.snapshot()['firewall4']
            import shlex
            matching=[line for line in current if shlex.split(line)==rule]
            require(len(matching)<=1,'duplicated owned firewall rule')
            if matching:
                self.mutate('firewall-remove-'+str(index),[SUDO,'-n',SW+'iptables','-w','5','-D','nixos-fw',*rule[2:]])
            require(not any(shlex.split(line)==rule for line in self.snapshot()['firewall4']),'owned firewall removal not verified')

    def install_firewall(self):
        import shlex
        with self.state.lock():
            require(self.cfg['firewallRules']==parent_firewall_rules(self.cfg),'firewall inventory differs from exact parent policy')
            current=self.check('direct-or-idle')
            require(current['interfaces'][self.cfg['directInterface']]['uuid']==self.cfg['profileUuid'],'parent direct UUID not active')
            self.modules['deuces-direct-cleanup.py'].verify_pair_armed(self.state,self.modules)
            self.modules['deuces-direct-lease.py'].Lease(self.state).check(self.cfg['launchReserveSeconds'])
            for i,rule in enumerate(self.cfg['firewallRules']):
                require(not any(shlex.split(row)==rule for row in current['firewall4']),'parent firewall collision, never adopt')
                self.mutate('firewall-insert-'+str(i),[SUDO,'-n',SW+'iptables','-w','5','-I','nixos-fw','1',*rule[2:]])
                current=self.check('direct-or-idle')
                require(sum(shlex.split(row)==rule for row in current['firewall4'])==1,'parent rule canonical readback failed')
            self.state.write('phase-firewall-ready.json',rules=self.cfg['firewallRules'])
            return current

    def entry_intents(self):
        require(self.state.read('phase-transition-started.json')['phase']=='switch-to-idle','not an owned entry transition')
        require(not (self.state.root/'phase-idle.json').exists() and
                not (self.state.root/'phase-direct-ready.json').exists() and
                not (self.state.root/'phase-restore-started.json').exists(), 'partial entry cannot cover later phases')
        expected={'fabric-stop':[SUDO,'-n',SW+'systemctl','stop','cluster-fabric-profile.service']}
        for nic in self.cfg['switchInterfaces']:
            expected['switch-disconnect-'+nic]=[SUDO,'-n',SW+'nmcli','--wait','10','connection','down','uuid',self.cfg['switchUuids'][nic]]
            expected['switch-admin-down-'+nic]=[SUDO,'-n',SW+'ip','link','set',nic,'down']
        attempted=set()
        for label,argv in expected.items():
            path=self.state.root/(label+'-intent.json')
            if path.exists():
                require(self.state.read(path.name).get('argv')==argv,'partial entry intent argv changed')
                attempted.add(label)
        require('fabric-stop' in attempted,'missing fabric stop intent')
        for i,nic in enumerate(self.cfg['switchInterfaces']):
            if any('switch-'+kind+'-'+nic in attempted for kind in ('disconnect','admin-down')):
                require((self.state.root/'fabric-stop-done.json').exists(),'interface action without completed fabric stop')
                require(self.state.read('fabric-stop-done.json').get('argv')==expected['fabric-stop'],'fabric completion argv changed')
                if i:
                    previous='switch-admin-down-'+self.cfg['switchInterfaces'][i-1]
                    require((self.state.root/(previous+'-done.json')).exists() and
                            self.state.read(previous+'-done.json').get('argv')==expected[previous], 'interface order not proved')
        return attempted

    def restore_switch(self):
        """Called only after either a validated idle or intent-bound entry."""
        self.mutate('fabric-start',[SUDO,'-n',SW+'systemctl','start','cluster-fabric-profile.service'])
        for interface in self.cfg['switchInterfaces']:
            self.mutate('switch-up-'+interface,[SUDO,'-n',SW+'nmcli','--wait','20','connection','up','uuid',self.cfg['switchUuids'][interface]])
            self.mutate('switch-metric-'+interface,[SUDO,'-n',SW+'nmcli','device','modify',interface,'ipv4.route-metric',str(self.cfg['switchMetrics'][interface])])
            original=self.original['interfaces'][interface]
            self.mutate('switch-mtu-'+interface,[SUDO,'-n',SW+'ip','link','set',interface,'mtu',str(original['mtu'])])
            arp=original['arp']
            self.mutate('switch-arp-'+interface,[SUDO,'-n',SW+'sysctl','-qw',f'net.ipv4.conf.{interface}.arp_ignore={arp[0]}',f'net.ipv4.conf.{interface}.arp_announce={arp[1]}'])
        after=self.check_settled('switched')
        self.state.write('phase-switched-restored.json',phase='switched',snapshot=after)
        return after

    def restore(self):
        with self.state.lock():
            # This bridge must perform real exact-unit/leaf verification and
            # query BOTH nodes. Missing bridge/proof blocks all network writes.
            self.modules['deuces-direct-cleanup.py'].verify_pair_stopped(self.state,modules=self.modules)
            if self.predeclared:
                entered=self.state.root/'phase-idle.json'
                if not entered.exists():
                    forbidden=('fabric-','switch-','direct-','firewall-','phase-')
                    require(not any(p.name.startswith(forbidden) for p in self.state.root.iterdir()),'unstarted predeclared peer has network intent/phase')
                    after=self.predeclared_final(self.preflight())
                    self.state.write('phase-predeclared-unchanged.json',phase='predeclared-direct',reason='never-entered',snapshot=after)
                    return after
                require(self.state.read('phase-idle.json').get('phase')=='predeclared-direct' and
                        not (self.state.root/'phase-transition-started.json').exists(),'predeclared entry proof conflicts with switched transition')
                completed=self.state.root/'phase-predeclared-restored.json'
                if completed.exists():
                    saved=self.state.read(completed.name)
                    require(set(saved)=={'owner','configSha256','phase','snapshot'} and
                            saved['phase']=='predeclared-direct','predeclared restored receipt changed')
                    self.predeclared_final(saved['snapshot'])
                    after=self.predeclared_final(self.preflight())
                    return after
                self.check('direct-or-idle')
                marker=dict(phase='predeclared-direct-cleanup')
                if (self.state.root/'phase-restore-started.json').exists():
                    saved=self.state.read('phase-restore-started.json')
                    require(set(saved)=={'owner','configSha256','phase'} and saved['phase']==marker['phase'],
                            'predeclared restore marker changed')
                else:self.state.write('phase-restore-started.json',**marker)
                self.remove_firewall()
                after=self.predeclared_final(self.preflight())
                self.state.write('phase-predeclared-restored.json',phase='predeclared-direct',snapshot=after)
                return after
            if not (self.state.root/'phase-transition-started.json').exists():
                # A peer can be closed before enter_idle was called. Prove its
                # exact unchanged baseline and absence of EVERY network intent;
                # do not pretend restoration commands were executed.
                forbidden=('fabric-','switch-','direct-','firewall-','phase-')
                require(not any(p.name.startswith(forbidden) for p in self.state.root.iterdir()),'unstarted peer has network intent/phase')
                after=self.check('switched')
                self.state.write('phase-switched-unchanged.json',phase='switched',reason='never-transitioned',snapshot=after)
                return after
            if (self.state.root/'phase-transition-started.json').exists() and not (self.state.root/'phase-idle.json').exists():
                current=self.check_settled('entry-partial',attempted=self.entry_intents())
                self.state.write('phase-restore-started.json',phase='partial-entry-to-switched')
                # Wrapper could not have started: f0/profile/firewall must be
                # exactly original, so this branch never touches them.
                return self.restore_switch()
            current=self.check('direct-or-idle')
            self.state.write('phase-restore-started.json',phase='fallback-to-idle')
            self.remove_firewall()
            nic=self.cfg['directInterface'];uuid=self.cfg['profileUuid'];profile=self.cfg['profileName']
            inventory=self.run([SW+'nmcli','-t','-f','NAME,UUID,TYPE','connection','show']).splitlines()
            line=profile+':'+uuid+':802-3-ethernet'
            require(inventory.count(line)<=1 and not any(uuid in row and row!=line for row in inventory),'owned direct UUID identity changed')
            if line in inventory:
                fields=self.run([SW+'nmcli','-g','connection.id,connection.interface-name,connection.autoconnect,ipv4.method,ipv4.addresses,ipv6.method,802-3-ethernet.mtu','connection','show','uuid',uuid]).splitlines()
                require(fields==[profile,nic,'no','manual',self.cfg['cidr'],'disabled',str(self.cfg['mtu'])],'direct profile configuration changed')
                active=self.run([SW+'nmcli','-g','GENERAL.CON-UUID','device','show',nic]).strip()
                require(active in ('','--',uuid),'foreign direct active profile')
                if active==uuid:self.mutate('direct-down',[SUDO,'-n',SW+'nmcli','--wait','10','connection','down','uuid',uuid])
                require(self.run([SW+'nmcli','-g','GENERAL.CON-UUID','device','show',nic]).strip() in ('','--'),'direct profile remains active')
                self.mutate('direct-delete',[SUDO,'-n',SW+'nmcli','connection','delete','uuid',uuid])
            require(uuid not in self.run([SW+'nmcli','-t','-f','UUID','connection','show']).splitlines(),'direct profile still present')
            before=self.original['interfaces'][nic]
            self.mutate('direct-mtu',[SUDO,'-n',SW+'ip','link','set',nic,'mtu',str(before['mtu'])])
            self.mutate('direct-admin',[SUDO,'-n',SW+'ip','link','set',nic,'up' if before['adminUp'] else 'down'])
            for interface in (nic,self.cfg['siblingInterface']):
                arp=self.original['interfaces'][interface]['arp']
                self.mutate('direct-arp-'+interface,[SUDO,'-n',SW+'sysctl','-qw',f'net.ipv4.conf.{interface}.arp_ignore={arp[0]}',f'net.ipv4.conf.{interface}.arp_announce={arp[1]}'])
            self.state.write('phase-idle-restored.json',phase='idle',snapshot=self.check('idle'))
            return self.restore_switch()
