#!/usr/bin/env python3
"""Candidate exact-slot transport and exclusive byte staging for link slots.

No network changes, fallback runner or PID signals. Stage requires a sealed
caller-owned plan and existing private parent; it never starts a worker/service.
Candidate shell integration is opt-in and not yet hardware-qualified.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys

# Verify staged bytes before executing them; a changed worker must not be
# trusted to attest its own source. Arguments are data, never shell fragments.
BOOTSTRAP = '''import hashlib,os,stat,sys
from pathlib import Path
py,state,seal,worker,owner,action=sys.argv[1:]
root=Path(state)
def need(ok):
 if not ok: raise RuntimeError("staged link slot changed")
need(root.is_absolute() and str(root.resolve())==state)
s=root.lstat()
need(stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o700)
contents={}
for name in ("worker.py","config.json","OWNER"):
 fd=os.open(root/name,os.O_RDONLY|os.O_NOFOLLOW)
 with os.fdopen(fd,"rb") as f:
  s=os.fstat(f.fileno())
  need(stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and stat.S_IMODE(s.st_mode)==0o600 and s.st_size<=1048576)
  contents[name]=f.read(1048577)
  need(len(contents[name])<=1048576)
need(hashlib.sha256(contents["worker.py"]).hexdigest()==worker)
need(hashlib.sha256(contents["config.json"]).hexdigest()==seal)
need(contents["OWNER"]==(owner+"\\n").encode())
os.chdir("/")
os.execv(py,[py,"-I",str(root/"worker.py"),action,state,seal])
'''

# Stage only bytes in a NEW slot. No worker code is executed and no service is
# started here. A lost reply leaves a consumed slot for explicit inspection;
# retries must never adopt or overwrite an existing directory.
STAGE_BOOTSTRAP = '''import base64,hashlib,json,os,stat,sys
from pathlib import Path
state,seal,worker,owner=sys.argv[1:]
def need(ok):
 if not ok: raise RuntimeError("link slot staging refused")
raw=sys.stdin.buffer.read(2097153)
need(len(raw)<=2097152)
body=json.loads(raw)
need(set(body)=={"worker","config"})
contents={"worker.py":base64.b64decode(body["worker"],validate=True),"config.json":base64.b64decode(body["config"],validate=True),"OWNER":(owner+"\\n").encode()}
need(all(len(x)<=1048576 for x in contents.values()))
need(hashlib.sha256(contents["worker.py"]).hexdigest()==worker)
need(hashlib.sha256(contents["config.json"]).hexdigest()==seal)
root=Path(state)
need(root.is_absolute() and str(root.parent.resolve(strict=True))==str(root.parent))
parent=os.open(root.parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
try:
 info=os.fstat(parent)
 need(info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o700)
 os.mkdir(root.name,mode=0o700,dir_fd=parent)
 slot=os.open(root.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
 try:
  for name,data in contents.items():
   fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=slot)
   with os.fdopen(fd,"wb") as f:
    f.write(data);f.flush();os.fsync(f.fileno())
  os.fsync(slot);os.fsync(parent)
  for name,data in contents.items():
   fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=slot)
   with os.fdopen(fd,"rb") as f:
    info=os.fstat(f.fileno())
    need(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)==0o600)
    need(f.read(1048577)==data)
 finally: os.close(slot)
finally: os.close(parent)
print(json.dumps({"version":1,"result":"pass","owner":owner,"state":state,"configSha256":seal,"workerSha256":worker,"scope":"staged-bytes-only"}))
'''


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def hexseal(value):
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None


def path(value):
    return isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9._/+:-]+", value) is not None and ".." not in Path(value).parts


def validate(plan):
    need(isinstance(plan, dict) and set(plan) == {"version", "owner", "helperSha256", "slots"}, "plan schema")
    need(type(plan["version"]) is int and plan["version"] == 1 and hexseal(plan["owner"]) and hexseal(plan["helperSha256"]), "plan identity")
    need(isinstance(plan["slots"], list) and 1 <= len(plan["slots"]) <= 16, "finite slot inventory")
    labels, states, units = set(), set(), set()
    for slot in plan["slots"]:
        need(isinstance(slot, dict) and set(slot) == {"host", "label", "state", "config", "configSha256"}, "slot schema")
        need(isinstance(slot["host"], str) and re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*", slot["host"]), "explicit SSH user/host")
        need(isinstance(slot["label"], str) and re.fullmatch(r"[a-z][a-z0-9-]{0,79}", slot["label"]), "slot label")
        need(path(slot["state"]) and re.fullmatch(r"gb10sor-link-server\.[a-f0-9]{32}", Path(slot["state"]).name), "owned state path")
        cfg = slot["config"]
        need(isinstance(cfg, dict) and hexseal(slot["configSha256"]) and digest(encoded(cfg)) == slot["configSha256"], "config seal")
        need(cfg.get("owner") == plan["owner"] and cfg.get("workerSha256") == plan["helperSha256"], "slot owner/source")
        need(isinstance(cfg.get("bootId"), str) and re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", cfg["bootId"]), "slot boot identity")
        need(cfg.get("unit") == Path(slot["state"]).name + ".service", "slot unit")
        need(path(cfg.get("python")) and cfg["python"].startswith("/nix/store/"), "cached Python path")
        need(type(cfg.get("stopSeconds")) is int and 1 <= cfg["stopSeconds"] <= 30, "stop bound")
        need(type(cfg.get("leaseSeconds")) is int and 30 <= cfg["leaseSeconds"] <= 900, "original finite lease")
        need(isinstance(cfg.get("argv"), list) and cfg["argv"] and all(isinstance(x, str) and x and "\0" not in x for x in cfg["argv"]), "server argv")
        # Full host/boot/closure/config validation remains in the sealed worker.
        # This layer never substitutes a local guess for that remote check.
        need(slot["label"] not in labels and (slot["host"], slot["state"]) not in states and
             (slot["host"], cfg["unit"]) not in units, "duplicate slot ownership")
        labels.add(slot["label"])
        states.add((slot["host"], slot["state"]))
        units.add((slot["host"], cfg["unit"]))
    return plan


def select(plan, host, label, server_argv=None):
    matches = [slot for slot in plan["slots"] if slot["host"] == host and slot["label"] == label]
    need(len(matches) == 1, "undeclared host/label")
    slot = matches[0]
    if server_argv is not None:
        need(server_argv == slot["config"]["argv"], "requested server differs from sealed argv")
    return slot


def remote_command(slot, action):
    need(action in ("stage", "prepare", "start", "inspect", "stop", "wait-success", "journal"), "unsupported action")
    cfg = slot["config"]
    if action == "stage":
        return shlex.join([cfg["python"], "-I", "-c", STAGE_BOOTSTRAP, slot["state"],
                           slot["configSha256"], cfg["workerSha256"], cfg["owner"]])
    return shlex.join([cfg["python"], "-I", "-c", BOOTSTRAP, cfg["python"], slot["state"],
                       slot["configSha256"], cfg["workerSha256"], cfg["owner"], action])


def positive(slot, action, output):
    value = json.loads(output)
    if action == "stage":
        need(value == {"version": 1, "result": "pass", "owner": slot["config"]["owner"],
             "state": slot["state"], "configSha256": slot["configSha256"],
             "workerSha256": slot["config"]["workerSha256"], "scope": "staged-bytes-only"},
             "staged byte receipt mismatch")
        need(type(value["version"]) is int, "stage version type")
        return value
    if action == "inspect":
        # Inspection can legitimately return null after verified stop; it is
        # NOT a substitute for the explicit immutable positive stop receipt.
        need(value is None or isinstance(value, dict), "malformed inspection")
        return value
    need(isinstance(value, dict) and value.get("result") == "pass", "no positive helper receipt")
    cfg = slot["config"]
    for key, expected in (("version", 1), ("owner", cfg["owner"]), ("unit", cfg["unit"]),
                          ("bootId", cfg.get("bootId")), ("configSha256", slot["configSha256"])):
        need(type(value.get(key)) is type(expected) and value.get(key) == expected, "receipt identity: " + key)
    return value


def private_read(filename, maximum=1024 * 1024, public=False):
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        forbidden = 0o022 if public else 0o077
        need(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & forbidden, "protected owned input required")
        need(info.st_size <= maximum, "input too large")
        data = stream.read(maximum + 1)
        need(len(data) <= maximum, "input grew beyond bound")
        return data


def publish(root, name, value):
    fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(encoded(value))
        stream.flush()
        os.fsync(stream.fileno())
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def dispatch(plan, seal, action, host, label, directory, identity, known, requested=None, worker=None):
    slot = select(plan, host, label, requested)
    remote = remote_command(slot, action)
    staged_input = None
    if action == "stage":
        need(isinstance(worker, bytes), "stage requires exact local helper source")
        need(digest(worker) == plan["helperSha256"], "staging helper source changed")
        staged_input = json.dumps({"worker": base64.b64encode(worker).decode(),
                                  "config": base64.b64encode(encoded(slot["config"])).decode()})
        need(len(staged_input.encode()) <= 2097152, "stage request too large")
    for item in (identity, known):
        need(path(item), "absolute SSH input path")
    private_read(identity)
    private_read(known, public=True)
    evidence = Path(directory)
    need(evidence.is_absolute() and str(evidence.resolve()) == str(evidence), "canonical evidence path")
    info = evidence.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, "private receipt directory")
    prefix = label + "-" + action
    args = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", identity,
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + known,
            "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", host, remote]
    publish(evidence, prefix + "-intent.json", {"planSha256": seal, "slot": slot, "action": action, "argv": args})
    # Ambiguous transport outcomes retain the intention and fail. There is no
    # fallback, retry, PID search, unit adoption, or network restoration here.
    try:
        io = {"input": staged_input} if staged_input is not None else {"stdin": subprocess.DEVNULL}
        # Remote wait-success is capped by the ORIGINAL prepared deadline.
        # This transport allowance does not renew or extend that lease.
        allowance = slot["config"]["leaseSeconds"] if action == "wait-success" else 0
        result = subprocess.run(args, **io, capture_output=True, text=True,
                                timeout=allowance + slot["config"]["stopSeconds"] + 60)
    except subprocess.TimeoutExpired as exc:
        publish(evidence, prefix + "-ambiguous.json", {"planSha256": seal, "action": action,
                "reason": "transport-timeout", "timeoutSeconds": exc.timeout})
        raise
    publish(evidence, prefix + "-reply.json", {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr})
    need(result.returncode == 0, "helper transport failed/ambiguous; exact slot still owned")
    value = positive(slot, action, result.stdout)
    publish(evidence, prefix + "-verified.json", {"planSha256": seal, "action": action, "receipt": value})
    return value


def batch(plan, seal, action, directory, identity, known, worker=None):
    """Caller-owned finite inventory. Cleanup attempts ALL slots despite errors."""
    need(action in ("stage-all", "cleanup-all"), "batch action")
    root = Path(directory)
    need(root.is_absolute() and str(root.resolve()) == str(root), "canonical batch receipts")
    info = root.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, "private batch receipt directory")
    publish(root, "batch-intent.json", dict(action=action, planSha256=seal, plan=plan))
    outcomes = []
    for slot in plan["slots"]:
        outcome = dict(host=slot["host"], label=slot["label"], result="failed")
        try:
            location = root / slot["label"]
            location.mkdir(mode=0o700)
            actual = "stage" if action == "stage-all" else "stop"
            receipt = dispatch(plan, seal, actual, slot["host"], slot["label"], location, identity, known, worker=worker)
            if action == "cleanup-all":
                inspected = dispatch(plan, seal, "inspect", slot["host"], slot["label"], location, identity, known)
                need(inspected is None, "declared link slot not positively stopped")
            outcome.update(result="pass", receipt=receipt)
        except Exception as exc:
            outcome["error"] = str(exc)
        outcomes.append(outcome)
        # Staging is bytes only; never proceed to more slots after a failure.
        # Cleanup must still try every remaining exact owned slot.
        if outcome["result"] != "pass" and action == "stage-all": break
    result = dict(version=1, owner=plan["owner"], planSha256=seal, action=action, slots=outcomes,
                  result="pass" if len(outcomes) == len(plan["slots"]) and all(x["result"] == "pass" for x in outcomes) else "failed",
                  scope="staged-bytes-only" if action == "stage-all" else "declared-link-resource-cleanup-only")
    publish(root, "batch-result.json", result)
    need(result["result"] == "pass", "batch incomplete/failed; no network restoration authorized")
    return result


def main():
    if len(sys.argv) >= 5 and sys.argv[1] in ("check", "check-pair"):
        data = private_read(sys.argv[2])
        need(hexseal(sys.argv[3]) and digest(data) == sys.argv[3], "plan changed")
        plan = validate(json.loads(data))
        labels = sys.argv[4:]
        if sys.argv[1] == "check-pair":
            need(len(sys.argv) >= 9, "check-pair needs LEFT_HOST LEFT_NODE RIGHT_HOST RIGHT_NODE LABELS")
            left_host, left_node, right_host, right_node = sys.argv[4:8]
            need(left_host != right_host and left_node != right_node, "distinct declared pair")
            labels = sys.argv[8:]
            for slot in plan["slots"]:
                matched = re.fullmatch(r"(?:rail|rdma)-a-(left-to-right|right-to-left)(-client)?", slot["label"])
                need(matched is not None, "single-port pair label")
                is_left = (matched[1] == "left-to-right") == bool(matched[2])
                expected = (left_host, left_node) if is_left else (right_host, right_node)
                need((slot["host"], slot["config"].get("hostname")) == expected, "planned slot belongs to another pair/node")
        need(len(labels) == len(set(labels)) and sorted(labels) == sorted(x["label"] for x in plan["slots"]), "incomplete/extra planned inventory")
        print(json.dumps({"result": "pass", "owner": plan["owner"], "labels": sorted(labels)}))
        return
    if len(sys.argv) in (7, 8) and sys.argv[1] in ("stage-all", "cleanup-all"):
        action, filename, seal, directory, identity, known = sys.argv[1:7]
        need(len(sys.argv) == (8 if action == "stage-all" else 7), "batch arguments")
        data = private_read(filename)
        need(hexseal(seal) and digest(data) == seal, "plan changed")
        worker = private_read(sys.argv[7], public=True) if action == "stage-all" else None
        value = batch(validate(json.loads(data)), seal, action, directory, identity, known, worker)
    else:
        need(len(sys.argv) >= 9, "ACTION PLAN PLAN_SHA HOST LABEL RECEIPT_DIR IDENTITY_FILE KNOWN_HOSTS [SERVER_ARGV...]")
        action, filename, seal, host, label, directory, identity, known = sys.argv[1:9]
        data = private_read(filename)
        need(hexseal(seal) and digest(data) == seal, "plan changed")
        requested = sys.argv[9:] if action == "start" else None
        need(action == "start" or len(sys.argv) == (10 if action == "stage" else 9), "unexpected action arguments")
        worker = private_read(sys.argv[9], public=True) if action == "stage" else None
        value = dispatch(validate(json.loads(data)), seal, action, host, label, directory, identity, known, requested, worker)
    print(json.dumps(value, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"result": "failed", "error": str(exc)}), file=sys.stderr)
        sys.exit(1)
