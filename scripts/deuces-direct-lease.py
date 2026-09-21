"""Actual finite user-unit policy for a sealed per-node network rollback.

No commands run on import. This is used only by the narrowly scoped direct
guard, not a general task scheduler. The rollback worker itself must verify
controller/resource termination before restoring any network state.
"""
from fractions import Fraction
import json
import os
from pathlib import Path
import re
import subprocess
import time


def require(ok, why):
    if not ok: raise RuntimeError(why)


def duration(value):
    require(isinstance(value,str) and 0 < len(value) < 80, 'finite systemd duration required')
    total=Fraction(0)
    for part in value.split():
        match=re.fullmatch(r'([0-9]+(?:\.[0-9]+)?)(w|d|h|min|s|ms|us)',part)
        require(match is not None,'unknown/unbounded systemd duration')
        total+=Fraction(match[1])*{'w':604800000000,'d':86400000000,'h':3600000000,'min':60000000,'s':1000000,'ms':1000,'us':1}[match[2]]
    require(total.denominator==1,'fractional microsecond duration')
    return int(total)


def exact_exec(value, argv):
    match=re.fullmatch(r'\{ path=([^;]+) ; argv\[\]=([^;]+) ; ignore_errors=no ; ([^{}]*) \}',value)
    require(match is not None and match[1]==argv[0] and match[2]==' '.join(argv),'changed rollback ExecStart')


def properties(text):
    result={}
    for line in text.splitlines():
        require('=' in line,'invalid unit property')
        name,value=line.split('=',1);require(name not in result,'duplicate unit property');result[name]=value
    return result


def command(argv, timeout=15):
    return subprocess.run(argv,timeout=timeout,cwd='/',capture_output=True,text=True)


class Lease:
    def __init__(self,state,run=command,clock=time.monotonic):
        self.state=state;self.cfg=state.config;self.run=run;self.clock=clock
        self.unit=self.cfg['rollbackUnit']
        require(re.fullmatch(r'gb10sor-direct-rollback-[0-9a-f]{32}',self.unit),'unique rollback unit required')
        for key,low,high in (('rollbackDelaySeconds',600,86400),('rollbackExecutionSeconds',240,3600),('rollbackStopSeconds',5,30)):
            require(type(self.cfg[key]) is int and low<=self.cfg[key]<=high,'finite rollback policy: '+key)
        for value in (self.cfg['python'],self.cfg['systemctl'],self.cfg['systemdRun']):
            require(isinstance(value,str) and re.fullmatch('/nix/store/[A-Za-z0-9._/+:-]+',value),'pinned rollback tool path')

    def argv(self):
        return [self.cfg['python'],'-I','-B',str(self.state.root/'deuces-direct-guard.py'),'recover',str(self.state.root),self.state.seal]

    def show(self,suffix):
        require(suffix in ('.timer','.service'),'fixed unit suffix')
        keys=('Id','LoadState','Description','ActiveState','SubState','MainPID','InvocationID','ControlGroup',
              'Type','RemainAfterExit','Restart','KillMode','TimeoutStartUSec','TimeoutStopUSec','WorkingDirectory',
              'ExecStart','Result','ExecMainPID','ExecMainCode','ExecMainStatus','AccuracyUSec','Triggers','NextElapseUSecMonotonic')
        result=self.run([self.cfg['systemctl'],'--user','show',self.unit+suffix,*[x for key in keys for x in ('-p',key)]])
        require(result.returncode in (0,4),'rollback query failed')
        value=properties(result.stdout)
        require(value.get('Id')==self.unit+suffix and value.get('LoadState') in ('loaded','not-found'),'rollback unit query identity')
        if value['LoadState']=='not-found':
            require(value.get('ActiveState')=='inactive' and value.get('SubState')=='dead','ambiguous missing rollback unit')
            # Timer units do not have a MainPID property in systemd261. Their
            # triggered service is queried and validated separately.
            require(value.get('MainPID') in (None,'0') if suffix=='.timer' else value.get('MainPID')=='0','ambiguous missing rollback process state')
        else: require(result.returncode==0,'loaded rollback query failed')
        return value

    def service_policy(self,value):
        require(value.get('Id')==self.unit+'.service' and value.get('LoadState')=='loaded' and value.get('Description')==self.state.owner,'rollback service owner')
        for key,expected in dict(Type='oneshot',RemainAfterExit='yes',Restart='no',KillMode='control-group',WorkingDirectory='/').items():
            require(value.get(key)==expected,'rollback policy changed: '+key)
        require(duration(value.get('TimeoutStartUSec'))==self.cfg['rollbackExecutionSeconds']*1000000 and
                duration(value.get('TimeoutStopUSec'))==self.cfg['rollbackStopSeconds']*1000000,'rollback execution bound changed')
        exact_exec(value.get('ExecStart',''),self.argv())

    def prepare(self):
        self.state.sources()
        for suffix in ('.timer','.service'):require(self.show(suffix)['LoadState']=='not-found','rollback unit collision')
        now=self.clock()
        return self.state.write('lease-prepared.json',preparedAt=now,deadline=now+self.cfg['rollbackDelaySeconds'])

    def arm(self):
        self.state.sources();prepared=self.state.read('lease-prepared.json')
        require(not (self.state.root/'lease-arm-intent.json').exists(),'rollback arm already attempted; no renewed deadline')
        for suffix in ('.timer','.service'):require(self.show(suffix)['LoadState']=='not-found','rollback unit collision before arm')
        # Reserve the whole 15-second dispatch plus one second of accuracy;
        # dispatch may not silently
        # renew a lease. The firing worker rechecks the original local deadline.
        remaining=int(prepared['deadline']-self.clock())-16
        require(remaining>=120,'insufficient rollback preparation budget')
        argv=[self.cfg['systemdRun'],'--user','--unit='+self.unit,'--description='+self.state.owner,
              '--on-active='+str(remaining)+'s','--timer-property=AccuracySec=1s',
              '--property=Type=oneshot','--property=RemainAfterExit=yes','--property=Restart=no',
              '--property=KillMode=control-group','--property=WorkingDirectory=/',
              '--property=TimeoutStartSec='+str(self.cfg['rollbackExecutionSeconds'])+'s',
              '--property=TimeoutStopSec='+str(self.cfg['rollbackStopSeconds'])+'s',
              '--setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin',*self.argv()]
        self.state.write('lease-arm-intent.json',argv=argv,remainingSeconds=remaining,originalDeadline=prepared['deadline'])
        result=self.run(argv)
        require(result.returncode==0,'rollback arm failed/lost reply; preserve original intent')
        timer,service=self.show('.timer'),self.show('.service')
        self.service_policy(service)
        require(timer.get('LoadState')=='loaded' and timer.get('Description')==self.state.owner and
                timer.get('ActiveState')=='active' and timer.get('SubState')=='waiting' and
                re.fullmatch('[0-9a-f]{32}',timer.get('InvocationID','')) and
                duration(timer.get('AccuracyUSec'))==1000000 and timer.get('Triggers')==self.unit+'.service','rollback timer identity/policy')
        require(self.clock()*1000000 < duration(timer.get('NextElapseUSecMonotonic')) <= prepared['deadline']*1000000,'timer exceeds original deadline')
        require(service.get('ActiveState')=='inactive' and service.get('SubState')=='dead' and service.get('MainPID')=='0','rollback already firing')
        self.state.write('lease-armed.json',timer=timer,service=service,originalDeadline=prepared['deadline'])
        return self.check(120)

    def check(self,reserve):
        require(type(reserve) is int and reserve>=0,'remaining deadline reserve')
        self.state.sources();saved=self.state.read('lease-armed.json');prepared=self.state.read('lease-prepared.json')
        require(saved['originalDeadline']==prepared['deadline'] and self.clock()+reserve<prepared['deadline'],'original rollback deadline exhausted')
        timer,service=self.show('.timer'),self.show('.service')
        for key in ('Id','Description','InvocationID','Triggers','AccuracyUSec','NextElapseUSecMonotonic'):
            require(timer.get(key)==saved['timer'].get(key),'rollback timer replaced')
        require(timer.get('LoadState')=='loaded' and timer.get('ActiveState')=='active' and timer.get('SubState')=='waiting','rollback timer not waiting')
        self.service_policy(service)
        require(service.get('ActiveState')=='inactive' and service.get('SubState')=='dead' and service.get('MainPID')=='0','rollback service executing/unknown')
        require(self.clock()+reserve<prepared['deadline'],'rollback deadline elapsed during checks')
        return dict(result='pass',timer=timer,service=service,deadline=prepared['deadline'])

    def disarm(self):
        self.state.sources()
        receipts=[name for name in ('phase-switched-restored.json','phase-switched-unchanged.json','phase-predeclared-restored.json','phase-predeclared-unchanged.json') if (self.state.root/name).exists()]
        phase=self.state.read(receipts[0]).get('phase') if len(receipts)==1 else None
        require(len(receipts)==1 and phase in ('switched','predeclared-direct'),'network restoration/unchanged proof not positive')
        require((phase=='predeclared-direct')==(self.cfg.get('networkLifecycle')=='predeclared-direct'),'network lifecycle receipt mismatch')
        if receipts[0]=='phase-switched-unchanged.json':
            require(self.state.read(receipts[0]).get('reason')=='never-transitioned' and
                    not (self.state.root/'phase-transition-started.json').exists(),'unchanged proof conflicts with transition')
        if receipts[0]=='phase-predeclared-unchanged.json':
            require(self.state.read(receipts[0]).get('reason')=='never-entered' and
                    not (self.state.root/'phase-idle.json').exists(),'predeclared unchanged proof conflicts with entry')
        if receipts[0]=='phase-predeclared-restored.json':
            require(self.state.read('phase-idle.json').get('phase')=='predeclared-direct' and
                    self.state.read('phase-restore-started.json').get('phase')=='predeclared-direct-cleanup' and
                    not (self.state.root/'phase-transition-started.json').exists(),'predeclared restoration chain incomplete/conflicting')
        saved=self.state.read('lease-armed.json');timer,service=self.show('.timer'),self.show('.service')
        self.service_policy(service)
        require(service.get('ActiveState')=='inactive' and service.get('SubState')=='dead' and service.get('MainPID')=='0','rollback execution still active/unknown')
        require(timer.get('LoadState')=='loaded' and timer.get('Description')==self.state.owner and
                timer.get('InvocationID')==saved['timer']['InvocationID'] and timer.get('ActiveState')=='active' and timer.get('SubState')=='waiting','exact waiting rollback timer required')
        argv=[self.cfg['systemctl'],'--user','stop',self.unit+'.timer'];self.state.intent('lease-disarm',argv)
        result=self.run(argv);require(result.returncode==0,'rollback timer disarm failed/lost reply')
        final,service=self.show('.timer'),self.show('.service')
        require(final.get('ActiveState')=='inactive' and final.get('SubState')=='dead' and final.get('MainPID') in (None,'0'),'rollback timer remains active')
        if final['LoadState']=='loaded':require(final.get('Description')==self.state.owner and final.get('InvocationID') in ('',saved['timer']['InvocationID']),'rollback timer replaced')
        if service.get('LoadState')=='loaded':self.service_policy(service)
        else:
            require(service.get('LoadState')=='not-found' and service.get('Id')==self.unit+'.service' and
                    service.get('InvocationID')=='' and service.get('ControlGroup')=='','collected rollback service ambiguous')
        if final['LoadState']=='not-found':
            require(final.get('InvocationID')=='' and final.get('ControlGroup') in (None,'') and
                    final.get('NextElapseUSecMonotonic')=='infinity','collected timer still has execution/trigger')
        require(service.get('ActiveState')=='inactive' and service.get('SubState')=='dead' and service.get('MainPID')=='0','rollback service changed during disarm')
        return self.state.write('lease-disarmed.json',result='pass',timer=final,service=service)
