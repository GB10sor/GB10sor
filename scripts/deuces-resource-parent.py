"""Finite local engine parent; not an independent network rollback service.

Pins the pre-write declaration, forwards interruption, waits for cleanup and
validates positive child resource receipts. A missing receipt blocks restoration.
Run the complete wrapper under the separately qualified durable outer service;
this process alone cannot recover networking after host/process loss.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import re
import stat
import subprocess
import sys
import time


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HERE = Path(__file__).resolve().parent
C = load(HERE / "deuces-declaration-channel.py", "declaration_channel")
R = load(HERE / "deuces-resource-receipt.py", "resource_receipt")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_pins(engine):
    adapter = "".join(sha(HERE / name) + "  " + name + "\n" for name in
                      ("deuces-owned-adapter.py", "deuces-owned-adapter.sh"))
    return dict(engine=sha(HERE / f"deuces-{engine}-acceptance.sh"),
                containerHelper=sha(HERE / "deuces-owned-container.py"),
                hashHelper=sha(HERE / "cluster-weight-hash.sh"),
                adapter=hashlib.sha256(adapter.encode()).hexdigest())


def stopped_status(code):
    return code if code >= 0 else 128 - code


def pre_ack_config(value, expectation):
    """Optional, independently pinned durable-guard inventory replication."""
    if value is None: return None
    C.require(set(value) == {'helperPath','helperSha256','configPath','configSha256','timeoutSeconds'}, 'pre-ACK policy schema')
    C.require(type(value['timeoutSeconds']) is int and 1 <= value['timeoutSeconds'] <= 60, 'pre-ACK timeout1..60')
    for path_key, sha_key in (('helperPath','helperSha256'),('configPath','configSha256')):
        path = Path(value[path_key])
        C.require(path.is_absolute() and path.resolve(strict=True) == path and re.fullmatch('[0-9a-f]{64}',value[sha_key]), 'pre-ACK source path/pin')
        if path_key == 'helperPath':
            # Source files in a checkout are normally 0644; unlike private
            # configs they need not be secret. Still reject writable/foreign
            # files and symlinks, and verify the exact source digest.
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
            with os.fdopen(fd,'rb') as stream:
                info=os.fstat(stream.fileno())
                C.require(stat.S_ISREG(info.st_mode) and not info.st_mode & 0o022 and info.st_size<=1048576 and
                          (info.st_uid==os.getuid() or (str(path).startswith('/nix/store/') and info.st_uid==0)), 'protected pre-ACK source required')
                raw=stream.read(1048577);C.require(len(raw)<=1048576,'pre-ACK source grew')
        else: raw = C.read(path.parent,path.name)
        C.require(C.digest(raw) == value[sha_key], 'pre-ACK source/config changed')
    cfg = json.loads(C.read(Path(value['configPath']).parent,Path(value['configPath']).name), object_pairs_hook=C.pairs)
    C.require(cfg.get('version') == 1 and isinstance(cfg.get('guards'),list) and len(cfg['guards']) == 2, 'two predeclared guards required')
    for guard, node in zip(sorted(cfg['guards'],key=lambda x:x['rank']), sorted(expectation['nodes'],key=lambda x:x['rank'])):
        C.require(set(guard) == {'rank','host','node','stateRoot','configSha256'} and all(guard[k]==node[k] for k in ('rank','host','node')), 'pre-ACK guard node mismatch')
        C.require(Path(guard['stateRoot']).is_absolute() and '..' not in Path(guard['stateRoot']).parts and re.fullmatch('[0-9a-f]{64}',guard['configSha256']), 'pre-ACK guard identity')
    return cfg


def replicate_before_ack(policy, channel, evidence, state, expectation):
    cfg = pre_ack_config(policy, expectation)
    raw = C.read(channel,'offered.json')
    anchor = C.check(channel,raw)
    argv = [sys.executable,'-I','-B',policy['helperPath'],str(channel),str(evidence),policy['configPath'],policy['configSha256']]
    C.create(state,'pre-ack-intent.json',C.encoded(dict(version=1,policy=policy,argv=argv,declaration=anchor)))
    # The child remains unreaped until communicate completes. On a pipe/worker
    # timeout its freshly created session is still pinned; terminate that exact
    # group, not searched PIDs or unrelated remote resources. No ACK on failure.
    process = subprocess.Popen(argv, cwd='/', stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    C.create(state,'pre-ack-process.json',C.encoded(dict(pid=process.pid,session=process.pid)))
    try:
        stdout,stderr = process.communicate(timeout=policy['timeoutSeconds'])
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL)
        stdout,stderr=process.communicate(timeout=5)
        C.create(state,'pre-ack-failed.json',C.encoded(dict(result='failed',reason='callback timeout',exitCode=process.returncode)))
        raise ValueError('pre-ACK callback timeout; no model staging authorised')
    C.create(state,'pre-ack-stdout',stdout)
    C.create(state,'pre-ack-stderr',stderr)
    C.require(process.returncode == 0 and len(stdout)<=1048576 and len(stderr)<=65536, 'pre-ACK callback failed/oversized')
    result=json.loads(stdout,object_pairs_hook=C.pairs)
    C.require(set(result) == {'version','result','declaration','guards'} and result['version']==1 and result['result']=='pass' and result['declaration']==anchor, 'pre-ACK result identity')
    C.require(isinstance(result['guards'],list) and len(result['guards'])==2, 'both guard replications required')
    for actual,expected in zip(sorted(result['guards'],key=lambda x:x['rank']),sorted(cfg['guards'],key=lambda x:x['rank'])):
        C.require(set(actual)==set(expected)|{'inventorySha256','receiptSha256'} and all(actual[k]==v for k,v in expected.items()), 'replicated guard identity changed')
        C.require(all(re.fullmatch('[0-9a-f]{64}',actual[k]) for k in ('inventorySha256','receiptSha256')), 'missing positive guard replication digest')
    pre_ack_config(policy,expectation)
    C.require(C.read(channel,'offered.json')==raw, 'declaration changed during guard replication')
    C.create(state,'pre-ack-replication.json',C.encoded(result))
    return result


def execute(command, state, evidence, expectation, environment, runtime, grace,
            source_check=lambda: None, receipt_check=None, recipe_registry=None, pre_ack=None):
    """No shell command parsing. Tests inject only synthetic child processes."""
    C.require(type(runtime) is int and 1 <= runtime <= 86400, "finite parent runtime required")
    C.require(type(grace) is int and 1 <= grace <= 3600, "finite cleanup grace required")
    pre_ack_config(pre_ack,expectation)
    state, evidence = Path(state), Path(evidence)
    state.mkdir(mode=0o700)
    C.directory(state)
    channel = state / "parent-channel"
    C.initialize(channel, expectation)
    env = dict(environment, GB10_DEUCES_OWNED_LIFECYCLE="1",
               GB10_DEUCES_OWNED_INVOCATION_OWNER=expectation["invocationOwner"],
               GB10_DEUCES_DECLARATION_CHANNEL=str(channel),
               GB10_DEUCES_DECLARATION_HELPER_SHA256=sha(HERE / "deuces-declaration-channel.py"))
    meta = dict(version=1, invocationOwner=expectation["invocationOwner"],
                runtimeSeconds=runtime, cleanupGraceSeconds=grace,
                recipeRegistry=recipe_registry,
                preAck=pre_ack,
                sources={name: sha(HERE / name) for name in
                         ("deuces-resource-parent.py", "deuces-declaration-channel.py", "deuces-resource-receipt.py")})
    C.create(state, "parent-config.json", C.encoded(meta))
    child = None
    received = []
    previous = {}
    errors = []
    anchor = None
    interrupted = False
    expired = False
    receipt = None

    def capture(number, frame):
        received.append(number)

    def forward(number):
        # Popen's unreaped child pins its PID. Only its freshly created session
        # is signalled; never look up a process by a remembered numeric PID.
        if child.poll() is None:
            C.require(os.getpgid(child.pid) == child.pid, "owned child session changed")
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                C.require(child.poll() is not None, "owned process group vanished unexpectedly")

    try:
        source_check()
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[number] = signal.signal(number, capture)
        child = subprocess.Popen(command, env=env, start_new_session=True)
        C.create(state, "child-process.json", C.encoded(dict(pid=child.pid, session=child.pid)))
        deadline = time.monotonic() + runtime
        stopping = None
        while child.poll() is None:
            now = time.monotonic()
            if stopping is None and (received or now >= deadline):
                interrupted = bool(received)
                expired = not interrupted
                forward(signal.SIGTERM)
                stopping = now + grace
            if stopping is not None and now >= stopping:
                forward(signal.SIGKILL)
                errors.append("child exceeded cleanup grace; independent remote guards must be checked")
                break
            if anchor is None and stopping is None and (channel / "offered.json").exists():
                try:
                    source_check()
                    if pre_ack is not None:
                        replicate_before_ack(pre_ack,channel,evidence,state,expectation)
                        source_check()
                    anchor = C.acknowledge(channel)
                except Exception as error:
                    errors.append("declaration refused: " + str(error))
                    forward(signal.SIGTERM)
                    stopping = now + grace
            time.sleep(0.1)
        code = child.wait(timeout=10)
        if anchor is None:
            errors.append("no parent-anchored declaration")
        else:
            source_check()
            # Verify original anchored bytes again, then independently check
            # every declared container/hash leaf. Child exit0 is not cleanup.
            C.verify_ack(channel, (evidence / "owned/declaration.json").read_bytes())
            receipt = (receipt_check or R.validate)(evidence, expectation["invocationOwner"], anchor["declarationSha256"])
    except Exception as error:
        errors.append(str(error))
        if child is not None and child.poll() is None:
            forward(signal.SIGTERM)
            try:
                child.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                forward(signal.SIGKILL)
                child.wait(timeout=10)
        code = child.returncode if child is not None else 1
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
    result = dict(version=1, invocationOwner=expectation["invocationOwner"],
                  declaration=anchor, childExit=code, interrupted=interrupted,
                  timedOut=expired, errors=errors, resourceReceipt=receipt,
                  resources="pass" if receipt and receipt.get("result") == "pass" and not errors else "failed",
                  scope="child-resources-only-not-network-restoration")
    C.create(state, "parent-result.json", C.encoded(result))
    if result["resources"] != "pass":
        return 1
    if interrupted: return 130
    if expired: return 124
    return stopped_status(code)


def verify_saved(state, evidence):
    """Wrapper EXIT gate; requires the parent seal, never a child-provided hash."""
    state = C.directory(state)
    result = C.document(state, "parent-result.json")
    config = C.document(state, "parent-config.json")
    C.require(result["resources"] == "pass" and result["errors"] == [], "parent resources not positive")
    C.require(config["invocationOwner"] == result["invocationOwner"], "parent owner changed")
    for name, seal in config["sources"].items():
        C.require(name in ("deuces-resource-parent.py", "deuces-declaration-channel.py", "deuces-resource-receipt.py")
                  and sha(HERE / name) == seal, "parent source changed")
    C.require(set(config["sources"]) == {"deuces-resource-parent.py", "deuces-declaration-channel.py", "deuces-resource-receipt.py"}, "parent source manifest incomplete")
    registry = config.get("recipeRegistry")
    if registry is not None:
        C.require(set(registry) == {"path", "sha256"} and Path(registry["path"]).is_absolute(), "registry pin schema")
        C.require(sha(Path(registry["path"])) == registry["sha256"], "recipe registry changed")
    anchor = C.verify_ack(state / "parent-channel", (Path(evidence) / "owned/declaration.json").read_bytes())
    C.require(result["declaration"] == anchor, "parent anchor changed")
    if config.get('preAck') is not None:
        expectation=C.document(state/'parent-channel','expected.json')
        guards=pre_ack_config(config['preAck'],expectation)['guards']
        replication=C.document(state,'pre-ack-replication.json')
        C.require(replication.get('version')==1 and replication.get('result')=='pass' and replication.get('declaration')==anchor, 'missing pre-ACK replication proof')
        C.require(len(replication.get('guards',[]))==2, 'missing both guard replicas')
        for actual,expected in zip(sorted(replication['guards'],key=lambda x:x['rank']),sorted(guards,key=lambda x:x['rank'])):
            C.require(set(actual)==set(expected)|{'inventorySha256','receiptSha256'} and all(actual[k]==v for k,v in expected.items()) and
                      all(re.fullmatch('[0-9a-f]{64}',actual[k]) for k in ('inventorySha256','receiptSha256')), 'saved guard replication changed')
    return R.validate(evidence, config["invocationOwner"], anchor["declarationSha256"])


def main():
    C.require(sys.flags.isolated and not sys.flags.optimize, "Python -I required")
    if sys.argv[1] == "verify":
        print(json.dumps(verify_saved(sys.argv[2], sys.argv[3]), sort_keys=True))
        return 0
    engine = sys.argv[1]
    C.require(engine in ("vllm", "sglang"), "engine required")
    evidence = Path(os.environ["DEUCES_PAYLOAD_EVIDENCE_DIR"])
    C.require(evidence.is_absolute() and not evidence.is_symlink(), "absolute evidence path required")
    C.require(not evidence.exists() or (evidence.is_dir() and not any(evidence.iterdir())), "fresh empty evidence required")
    # Canonicalize only the already existing parent; no model paths are touched.
    evidence.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    evidence = evidence.parent.resolve() / evidence.name
    state = Path(str(evidence) + ".parent")
    pins = source_pins(engine)
    registry_path = Path(os.environ.get("DEUCES_MODEL_PROFILE_REGISTRY", str(HERE.parent / "model-profiles.json"))).resolve(strict=True)
    C.require(registry_path.is_file(), "recipe registry file required")
    registry = dict(path=str(registry_path), sha256=sha(registry_path))
    expectation = dict(invocationOwner=os.urandom(32).hex(), engine=engine, sourceSha256=pins,
                       nodes=[dict(rank=rank, host=os.environ[f"DEUCES_{side}_HOST"], node=os.environ[f"DEUCES_{side}_NODE"])
                              for rank, side in enumerate(("LEFT", "RIGHT"))])
    channel_sha = sha(HERE / "deuces-declaration-channel.py")

    def source_check():
        C.require(source_pins(engine) == pins and sha(HERE / "deuces-declaration-channel.py") == channel_sha,
                  "source changed during parent execution")
        C.require(sha(registry_path) == registry["sha256"], "recipe registry changed during execution")

    runtime = int(os.environ["GB10_DEUCES_PARENT_RUNTIME_SECONDS"])
    C.require(60 <= runtime <= 86400, "parent runtime range60..86400")
    env = dict(os.environ, DEUCES_PAYLOAD_EVIDENCE_DIR=str(evidence))
    pre_ack = None
    pre_ack_fields = ('GB10_DEUCES_PRE_ACK_HELPER','GB10_DEUCES_PRE_ACK_HELPER_SHA256','GB10_DEUCES_PRE_ACK_CONFIG','GB10_DEUCES_PRE_ACK_CONFIG_SHA256')
    if any(key in env for key in pre_ack_fields):
        C.require(all(env.get(key) for key in pre_ack_fields), 'partial pre-ACK configuration')
        pre_ack = dict(zip(('helperPath','helperSha256','configPath','configSha256'),(env[key] for key in pre_ack_fields)), timeoutSeconds=60)
    return execute([str(HERE / f"deuces-{engine}-acceptance.sh")], state, evidence,
                   expectation, env, runtime, 2400, source_check, recipe_registry=registry,pre_ack=pre_ack)


if __name__ == "__main__":
    sys.exit(main())
