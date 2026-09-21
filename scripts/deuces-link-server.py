#!/usr/bin/env python3
"""Candidate bounded user-service ownership for link-test servers; not wired.

Stage worker.py, config.json and OWNER in a new private state directory first.
API: Python -I worker.py ACTION STATE CONFIG_SHA256.
Actions: prepare, start, inspect, stop, wait-success, journal.
Client completion is natural exit0 only; benchmark acceptance is separate.
The internal exec action is only valid inside the exact declared service.
No firewall, interface, client traffic or switch changes; no PID-only signals.
"""
import fcntl
import base64
from contextlib import contextmanager
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import selectors
import stat
import subprocess
import sys
import time
import uuid


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def safe_path(value):
    return isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9._/+:-]+", value) and ".." not in Path(value).parts


def memlock_mode(cfg):
    if cfg["version"] == 1:
        return "unit-infinity" if cfg["memlockInfinity"] else "inherit"
    return cfg["memlock"]["mode"]


def trusted_executable(path, readable_nix=False):
    """Root-controlled path and every traversed symlink/ancestor, no writes.

    Execute-only sudo uses this OS metadata trust boundary, NOT a content hash.
    Root can replace it; the separately pinned boot/closure and before/after
    exact mapping/metadata checks are required. No user-writable ancestor is OK.
    """
    require(safe_path(path), "unsafe trusted executable path")
    if readable_nix:
        require(re.fullmatch(r"/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/[A-Za-z0-9._+-]+", path), "noncanonical Nix executable")
    pending = list(Path(path).parts[1:])
    current, links, store_boundary = Path("/"), [], None
    while True:
        info = current.lstat()
        if readable_nix and current == Path("/nix/store"):
            # Nix's root-owned sticky store is an explicit distinct boundary:
            # builders may add entries, but cannot replace root-owned entries.
            # This exception NEVER applies to sudo or to any store child.
            require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o1775, "unsafe sticky Nix store boundary")
            observed = {"path": str(current), "uid": info.st_uid, "gid": info.st_gid,
                        "mode": stat.S_IMODE(info.st_mode), "device": info.st_dev, "inode": info.st_ino}
            require(store_boundary is None or store_boundary == observed, "Nix store boundary changed")
            store_boundary = observed
        else:
            require(info.st_uid == 0 and info.st_gid == 0 and not info.st_mode & 0o022,
                    "writable/non-root trusted ancestor")
        require(stat.S_ISDIR(info.st_mode), "trusted ancestor is not directory")
        require(pending, "executable path is directory")
        entry = current / pending.pop(0)
        info = entry.lstat()
        if stat.S_ISLNK(info.st_mode):
            require(info.st_uid == 0 and info.st_gid == 0 and len(links) < 40, "untrusted symlink")
            target = os.readlink(entry)
            # Require a clean target rather than normalizing traversal silently.
            absolute = str(Path(target) if target.startswith("/") else current / target)
            require(safe_path(absolute), "unsafe symlink target")
            links.append({"path": str(entry), "target": target})
            pending = list(Path(absolute).parts[1:]) + pending
            current = Path("/")
        elif pending:
            current = entry
        else:
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == 0 and
                    not info.st_mode & 0o022 and info.st_mode & 0o111, "untrusted executable")
            value = {"resolved": str(entry), "device": info.st_dev, "inode": info.st_ino,
                     "uid": info.st_uid, "gid": info.st_gid, "mode": stat.S_IMODE(info.st_mode), "symlinks": links}
            if readable_nix:
                require(store_boundary is not None, "Nix boundary not observed")
                value["nixStoreBoundary"] = store_boundary
            return value


def verify_memlock_tools(policy):
    sudo, prlimit = policy["sudo"], policy["prlimit"]
    actual = trusted_executable(sudo["path"])
    require(actual == {k: sudo[k] for k in actual}, "sudo wrapper metadata/mapping changed")
    require(actual["mode"] & stat.S_ISUID, "sudo wrapper is not setuid")
    before = trusted_executable(prlimit["path"], readable_nix=True)
    require(before["resolved"] == prlimit["resolved"], "prlimit resolution changed")
    fd = os.open(before["resolved"], os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and (info.st_dev, info.st_ino, info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) ==
                tuple(before[k] for k in ("device", "inode", "uid", "gid", "mode")), "opened prlimit identity changed")
        digest = hashlib.sha256()
        while chunk := os.read(fd, 1024 * 1024):
            digest.update(chunk)
        require(digest.hexdigest() == prlimit["sha256"], "opened prlimit content changed")
        require(trusted_executable(prlimit["path"], readable_nix=True) == before, "prlimit changed during verification")
    finally:
        os.close(fd)
    return {"sudo": actual, "prlimit": before, "prlimitSha256": prlimit["sha256"]}


def command(argv, check=True, timeout=35):
    env = {"PATH": "/run/current-system/sw/bin:/usr/bin:/bin"}
    env.update({k: os.environ[k] for k in ("HOME", "USER", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS") if k in os.environ})
    result = subprocess.run(argv, cwd="/", env=env, text=True, capture_output=True, timeout=timeout)
    require(not check or result.returncode == 0, f"command failed: {argv[0]} status {result.returncode}: {result.stderr}")
    return result


def properties(text):
    result = {}
    for line in text.splitlines():
        require("=" in line, "malformed property")
        key, value = line.split("=", 1)
        require(key not in result, "duplicate property")
        result[key] = value
    return result


def duration(value):
    require(isinstance(value, str) and 0 < len(value) < 80, "missing duration")
    total = Fraction(0)
    for part in value.split():
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(min|ms|us|s)", part)
        require(match is not None, "unknown/unbounded duration")
        total += Fraction(match[1]) * {"min": 60000000, "s": 1000000, "ms": 1000, "us": 1}[match[2]]
    require(total.denominator == 1, "invalid duration precision")
    return int(total)


def exact_exec(value, argv):
    match = re.fullmatch(r"\{ path=([^;]+) ; argv\[\]=([^;]+) ; ignore_errors=no ; ([^{}]*) \}", value)
    require(match is not None and match[1] == argv[0] and match[2] == " ".join(argv), "ExecStart changed")


def private_file(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600,
            "non-private regular file: " + path.name)


def publish(root, name, value):
    # Positive receipts are immutable; cleanup cannot overwrite an old writer.
    temporary = root / ("." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.link(temporary, root / name)
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink()


@contextmanager
def ownership_lock(root):
    fd = os.open(root / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as lock:
        info = os.fstat(lock.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "foreign lock")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def bounded_journal(argv):
    """Bound the foreground query's captured bytes, not original workload bytes.

    Only this directly created Popen child can be terminated. There is no PID
    discovery or reused-PID signal, background supervisor or journal mutation.
    """
    limits = {"stdout": 1024 * 1024, "stderr": 64 * 1024}
    data = {key: bytearray() for key in limits}
    started = time.monotonic()
    deadline = started + 5
    timed_out, overflow = False, None
    proc = subprocess.Popen(argv, cwd="/", env={"PATH": "/run/current-system/sw/bin:/usr/bin:/bin", "LANG": "C"},
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as events:
            for name, stream in (("stdout", proc.stdout), ("stderr", proc.stderr)):
                os.set_blocking(stream.fileno(), False)
                events.register(stream, selectors.EVENT_READ, name)
            while events.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                for key, _mask in events.select(min(.1, remaining)):
                    name = key.data
                    chunk = os.read(key.fileobj.fileno(), min(65536, limits[name] - len(data[name]) + 1))
                    if not chunk:
                        events.unregister(key.fileobj)
                        continue
                    room = limits[name] - len(data[name])
                    data[name].extend(chunk[:room])
                    if len(chunk) > room:
                        overflow = name
                        break
                if overflow:
                    break
            remaining = deadline - time.monotonic()
            if not (timed_out or overflow) and remaining > 0:
                try:
                    proc.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    timed_out = True
            elif remaining <= 0:
                timed_out = True
    finally:
        if proc.poll() is None:
            proc.kill()  # Exact unreaped direct child object; no searched PID.
        try:
            proc.wait(timeout=2)
        finally:
            proc.stdout.close()
            proc.stderr.close()
    return {"exit": proc.returncode, "stdoutBase64": base64.b64encode(data["stdout"]).decode(),
            "stderrBase64": base64.b64encode(data["stderr"]).decode(), "stdoutBytes": len(data["stdout"]),
            "stderrBytes": len(data["stderr"]), "timedOut": timed_out, "overflow": overflow,
            "elapsedSeconds": time.monotonic() - started, "limits": limits}


def validate(cfg, root):
    require(type(cfg.get("version")) is int and cfg["version"] in (1, 2), "config version")
    require(set(cfg) == {"version", "owner", "hostname", "systemClosure", "bootId", "unit", "argv", "binarySha256",
                         "workerSha256", "python", "tools", "leaseSeconds", "stopSeconds",
                         "memlockInfinity" if cfg["version"] == 1 else "memlock"}, "config schema")
    require(re.fullmatch(r"gb10sor-link-server\.[0-9a-f]{32}", root.name), "state basename")
    require(cfg["unit"] == root.name + ".service", "unit is not derived from state")
    for key in ("owner", "binarySha256", "workerSha256"):
        require(isinstance(cfg[key], str) and re.fullmatch(r"[0-9a-f]{64}", cfg[key]), key)
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", cfg["hostname"]), "hostname")
    require(re.fullmatch(r"/nix/store/[a-z0-9]+-nixos-system-[A-Za-z0-9.+_-]+", cfg["systemClosure"]), "closure")
    require(re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", cfg["bootId"]), "boot identity")
    for key, low, high in (("leaseSeconds", 30, 900), ("stopSeconds", 1, 30)):
        require(type(cfg[key]) is int and low <= cfg[key] <= high, "finite " + key)
    if cfg["version"] == 1:
        require(type(cfg["memlockInfinity"]) is bool, "explicit memlock policy")
    else:
        policy = cfg["memlock"]
        require(isinstance(policy, dict) and policy.get("mode") in ("inherit", "unit-infinity", "scoped-prlimit"), "explicit v2 memlock policy")
        require(set(policy) == ({"mode", "before", "sudo", "prlimit"} if policy["mode"] == "scoped-prlimit" else {"mode"}), "memlock policy schema")
        if policy["mode"] == "scoped-prlimit":
            require(isinstance(policy["before"], list) and len(policy["before"]) == 2 and
                    all(type(x) is int and 0 <= x < 2**63 - 1 for x in policy["before"]) and
                    policy["before"][0] <= policy["before"][1], "finite expected prior memlock")
            sudo, prlimit = policy["sudo"], policy["prlimit"]
            require(isinstance(sudo, dict) and set(sudo) == {"trust", "path", "resolved", "device", "inode", "uid", "gid", "mode", "symlinks"} and
                    sudo["trust"] == "root-wrapper-metadata-v1", "explicit sudo metadata trust schema")
            require(sudo["path"] == "/run/wrappers/bin/sudo" and safe_path(sudo["resolved"]) and
                    sudo["resolved"].startswith("/run/wrappers/"), "sudo wrapper path")
            require(all(type(sudo[k]) is int and sudo[k] > 0 for k in ("device", "inode")) and
                    type(sudo["uid"]) is int and sudo["uid"] == 0 and type(sudo["gid"]) is int and sudo["gid"] == 0 and
                    type(sudo["mode"]) is int and 0 <= sudo["mode"] <= 0o7777 and sudo["mode"] & stat.S_ISUID and
                    not sudo["mode"] & 0o022 and sudo["mode"] & 0o111, "sudo wrapper ownership/mode")
            require(isinstance(sudo["symlinks"], list) and 1 <= len(sudo["symlinks"]) <= 40 and
                    all(isinstance(x, dict) and set(x) == {"path", "target"} and safe_path(x["path"]) and
                        isinstance(x["target"], str) and safe_path(str(Path(x["target"]) if x["target"].startswith("/") else Path(x["path"]).parent / x["target"]))
                        for x in sudo["symlinks"]), "sudo symlink mapping")
            require(isinstance(prlimit, dict) and set(prlimit) == {"path", "resolved", "sha256"}, "prlimit schema")
            require(all(isinstance(prlimit[k], str) and re.fullmatch(r"/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/[A-Za-z0-9._+-]+", prlimit[k]) for k in ("path", "resolved")) and
                    re.fullmatch(r"[0-9a-f]{64}", prlimit["sha256"]), "immutable readable prlimit pin")
    require(set(cfg["tools"]) == {"systemctl", "systemd-run", "hostname"}, "tool schema")
    for value in (str(root), cfg["python"], *cfg["tools"].values()):
        require(isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9._/+:-]+", value) and ".." not in Path(value).parts, "safe absolute path")
    argv = cfg["argv"]
    require(isinstance(argv, list) and 1 <= len(argv) <= 64 and
            all(isinstance(x, str) and re.fullmatch(r"[A-Za-z0-9._/=:,+%-]+", x) for x in argv), "unambiguous argv")
    require(re.fullmatch(r"/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/[A-Za-z0-9._+-]+", argv[0]), "immutable tool path")


def group_empty(group, base=Path("/sys/fs/cgroup")):
    require(re.fullmatch(r"/user.slice/[A-Za-z0-9_./@:-]+\.service", group) is not None and ".." not in Path(group).parts, "unsafe cgroup")
    require((base / "cgroup.controllers").is_file(), "cgroup v2 hierarchy unavailable")
    path = base / group.lstrip("/")
    try:
        info = path.lstat()
    except FileNotFoundError:
        # A previously recorded kernel group can disappear only when empty.
        return True
    require(stat.S_ISDIR(info.st_mode), "cgroup is not directory")
    def walk(directory):
        procs = directory / "cgroup.procs"
        info = procs.lstat()  # Missing/unreadable root or descendant is unknown.
        require(stat.S_ISREG(info.st_mode), "cgroup.procs is not regular")
        if procs.read_text().strip():
            return False
        for entry in directory.iterdir():
            info = entry.lstat()
            require(not stat.S_ISLNK(info.st_mode), "unexpected cgroup symlink")
            if stat.S_ISDIR(info.st_mode) and not walk(entry):
                return False
        return True
    return walk(path)


def process_identity(pid):
    root = Path("/proc") / str(pid)
    data = (root / "stat").read_text()
    start = int(data[data.rindex(")") + 2:].split()[19])
    groups = (root / "cgroup").read_text().splitlines()
    require(len(groups) == 1 and groups[0].startswith("0::"), "unified process cgroup required")
    return {"pid": pid, "startTicks": start, "cgroup": groups[0][3:]}


class Server:
    def __init__(self, root, cfg, seal):
        self.root, self.cfg, self.seal = Path(root), cfg, seal

    def tool(self, name, *args, **kwargs):
        return command([self.cfg["tools"][name], *args], **kwargs)

    def write(self, name, **fields):
        value = {"version": 1, "owner": self.cfg["owner"], "configSha256": self.seal,
                 "unit": self.cfg["unit"], "bootId": self.cfg["bootId"], **fields}
        publish(self.root, name, value)
        return value

    def read(self, name):
        path = self.root / name
        private_file(path)
        value = json.loads(path.read_text())
        require(all(value.get(k) == v for k, v in (("version", 1), ("owner", self.cfg["owner"]),
                ("configSha256", self.seal), ("unit", self.cfg["unit"]), ("bootId", self.cfg["bootId"]))), "receipt identity mismatch")
        return value

    def show(self, timeout=35):
        names = ("LoadState", "Id", "Description", "InvocationID", "ActiveState", "SubState", "MainPID", "ControlGroup",
                 "Result", "ExecMainPID", "ExecMainStatus", "ExecMainCode", "ExecStart", "Type", "RemainAfterExit", "Restart", "KillMode",
                 "RuntimeMaxUSec", "TimeoutStartUSec", "TimeoutStopUSec", "WorkingDirectory", "LimitCORE", "LimitMEMLOCK", "LimitMEMLOCKSoft")
        result = self.tool("systemctl", "--user", "show", self.cfg["unit"],
                           *[x for name in names for x in ("-p", name)], check=False, timeout=timeout)
        require(result.returncode in (0, 4), "unit query failed")
        value = properties(result.stdout)
        require(value.get("LoadState") in ("loaded", "not-found") and
                (result.returncode == 0 or value["LoadState"] == "not-found"), "unknown unit state")
        require(value.get("Id") == self.cfg["unit"], "unit query identity")
        if value["LoadState"] == "not-found":
            require(value.get("ActiveState") == "inactive" and value.get("SubState") == "dead" and value.get("MainPID") == "0",
                    "malformed collected/absent unit")
        return value

    def argv(self):
        return [self.cfg["python"], "-I", str(self.root / "worker.py"), "exec", str(self.root), self.seal]

    def policy(self, now, attempt):
        require(now.get("LoadState") == "loaded" and now.get("Id") == self.cfg["unit"] and
                now.get("Description") == self.cfg["owner"], "foreign unit")
        exact_exec(now.get("ExecStart", ""), self.argv())
        for key, expected in (("Type", "exec"), ("RemainAfterExit", "yes"), ("Restart", "no"),
                              ("KillMode", "control-group"), ("WorkingDirectory", "/"), ("LimitCORE", "0")):
            require(now.get(key) == expected, "service policy changed: " + key)
        for key, seconds in (("RuntimeMaxUSec", attempt["runtimeSeconds"]), ("TimeoutStartUSec", 15), ("TimeoutStopUSec", self.cfg["stopSeconds"])):
            require(duration(now.get(key)) == seconds * 1000000, "service time bound changed: " + key)
        if memlock_mode(self.cfg) == "unit-infinity":
            require(now.get("LimitMEMLOCK") == "infinity", "memlock not unlimited")
        if memlock_mode(self.cfg) == "scoped-prlimit":
            require([now.get("LimitMEMLOCKSoft"), now.get("LimitMEMLOCK")] == [str(x) for x in self.cfg["memlock"]["before"]],
                    "scoped mode inherited unit limits changed")

    def execution(self):
        attempt = self.read("start-attempted.json")
        require(attempt["argv"] == self.argv() and attempt["serverArgv"] == self.cfg["argv"], "start argv changed")
        saved = self.read("executing.json")
        require(re.fullmatch(r"[0-9a-f]{32}", saved.get("invocationId", "")), "missing executed invocation")
        require(saved.get("serverArgv") == self.cfg["argv"] and saved.get("binarySha256") == self.cfg["binarySha256"], "executed binary changed")
        require(type(saved.get("pid")) is int and saved["pid"] > 0 and type(saved.get("startTicks")) is int and saved["startTicks"] > 0,
                "invalid executed process identity")
        return saved

    def identify(self, now):
        saved = self.execution()
        self.policy(now, self.read("start-attempted.json"))
        require(now.get("InvocationID") == saved["invocationId"], "unit invocation changed or cleared")
        self.group_identity(now, saved)
        pid = int(now.get("MainPID", "-1"))
        require(pid >= 0, "unknown PID")
        if pid:
            require(pid == saved["pid"] and process_identity(pid) == {k: saved[k] for k in ("pid", "startTicks", "cgroup")}, "process identity changed")
        return saved

    def group_identity(self, now, saved):
        if now.get("ControlGroup") == saved["cgroup"]:
            return
        # Captured systemd behavior: terminal services can retain invocation and
        # exact ExecMainPID history while dropping the empty group. The exact
        # terminal predicates below qualify only resource cleanup; successful
        # client completion and traffic acceptance remain separate checks.
        natural = (now.get("ActiveState") == "active" and now.get("SubState") == "exited" and
                   now.get("Result") == "success" and now.get("ExecMainCode") == "1" and now.get("ExecMainStatus") == "0")
        expired = (now.get("ActiveState") == "failed" and now.get("SubState") == "failed" and
                   now.get("Result") == "timeout" and now.get("ExecMainCode") == "2" and now.get("ExecMainStatus") == "15")
        # A naturally failed client is a resource-cleanup fact, never client
        # completion. No signal/OOM/unknown-status generalization is made.
        status = now.get("ExecMainStatus", "")
        failed_exit = (now.get("LoadState") == "loaded" and now.get("ActiveState") == "failed" and
                       now.get("SubState") == "failed" and now.get("Result") == "exit-code" and
                       now.get("ExecMainCode") == "1" and isinstance(status, str) and
                       re.fullmatch(r"[1-9][0-9]{0,2}", status) is not None and 1 <= int(status) <= 255)
        require(now.get("ControlGroup") == "" and now.get("MainPID") == "0" and
                (natural or expired or failed_exit) and now.get("ExecMainPID") == str(saved["pid"]) and
                now.get("InvocationID") == saved["invocationId"], "unit cgroup changed or cleared without exact terminal history")
        require(group_empty(saved["cgroup"]), "recorded terminal group is not empty")

    def stop_intent(self):
        intent = self.read("before-stop.json")
        saved = self.execution()
        require(intent.get("intent") == "stop-exact-unit" and intent.get("invocationId") == saved["invocationId"] and
                intent.get("cgroup") == saved["cgroup"] and intent.get("workerArgv") == self.argv() and
                intent.get("serverArgv") == self.cfg["argv"], "stop intent changed")
        previous = intent["properties"]
        self.policy(previous, self.read("start-attempted.json"))
        require(previous.get("InvocationID") == saved["invocationId"] and
                previous.get("MainPID") in ("0", str(saved["pid"])), "stop intent process identity changed")
        self.group_identity(previous, saved)
        return intent, saved

    def stopped_state(self, now, saved):
        if now["LoadState"] == "loaded":
            self.policy(now, self.read("start-attempted.json"))
            require(now.get("InvocationID") in ("", saved["invocationId"]) and now.get("ControlGroup") in ("", saved["cgroup"]), "unit replaced during stop")
        require(now.get("ActiveState") in ("inactive", "failed") and now.get("SubState") in ("dead", "failed") and
                now.get("MainPID") == "0", "unit did not stop")
        require(group_empty(saved["cgroup"]), "owned descendants remain after stop")

    def prepare(self):
        require(not (self.root / "prepared.json").exists() and not (self.root / "canceled.json").exists(), "prepared/canceled state cannot be reused")
        require(self.show()["LoadState"] == "not-found", "unit collision")
        return self.write("prepared.json", result="pass", preparedAt=time.monotonic(), serverArgv=self.cfg["argv"])

    def start(self):
        prepared = self.read("prepared.json")
        require(not (self.root / "canceled.json").exists() and not (self.root / "start-attempted.json").exists(), "canceled/repeated start")
        require(self.show()["LoadState"] == "not-found", "unit collision")
        remaining = int(prepared["preparedAt"] + self.cfg["leaseSeconds"] - time.monotonic())
        require(remaining >= 20, "lease expired or insufficient start budget")
        # Reserve activation time; the worker separately refuses if delayed
        # activation would let RuntimeMaxSec extend the original deadline.
        remaining -= 15
        self.write("start-attempted.json", argv=self.argv(), serverArgv=self.cfg["argv"], runtimeSeconds=remaining)
        args = ["--user", "--unit=" + self.cfg["unit"], "--description=" + self.cfg["owner"],
                "--property=Type=exec", "--property=RemainAfterExit=yes", "--property=Restart=no",
                "--property=KillMode=control-group", "--property=RuntimeMaxSec=" + str(remaining) + "s",
                "--property=TimeoutStartSec=15s", "--property=TimeoutStopSec=" + str(self.cfg["stopSeconds"]) + "s",
                "--property=WorkingDirectory=/", "--property=LimitCORE=0", "--property=StandardOutput=journal",
                "--property=StandardError=journal"]
        if memlock_mode(self.cfg) == "unit-infinity":
            args.append("--property=LimitMEMLOCK=infinity")
        if memlock_mode(self.cfg) == "scoped-prlimit":
            args.append("--property=LimitMEMLOCK=" + ":".join(str(x) for x in self.cfg["memlock"]["before"]))
        self.tool("systemd-run", *args, "--", *self.argv())
        scoped = memlock_mode(self.cfg) == "scoped-prlimit"
        deadline = min(time.monotonic() + (10 if scoped else 5), self.read("prepared.json")["preparedAt"] + self.cfg["leaseSeconds"])
        readiness = "memlock-ready.json" if scoped else "executing.json"
        while not (self.root / readiness).exists() and time.monotonic() < deadline:
            time.sleep(.05)
        now = self.show()
        saved = self.identify(now)
        if scoped:
            ready = self.read("memlock-ready.json")
            require(ready.get("result") == "pass" and ready.get("invocationId") == saved["invocationId"] and
                    ready.get("process") == {k: saved[k] for k in ("pid", "startTicks", "cgroup")} and
                    ready.get("after") == [resource.RLIM_INFINITY, resource.RLIM_INFINITY] and
                    ready.get("policy") == self.cfg["memlock"] and time.monotonic() < deadline, "no current positive memlock readiness")
        require(now.get("ActiveState") == "active" and now.get("SubState") in ("running", "exited"), "server failed to start")
        return self.write("started.json", result="pass", invocationId=saved["invocationId"], properties=now)

    def inspect(self):
        now = self.show()
        if (self.root / "stopped.json").exists():
            self.verify_stopped(now)
            return None
        saved = self.identify(now)
        return {"properties": now, "executing": saved}

    def verify_observation_sources(self):
        for name in ("config.json", "worker.py", "OWNER"):
            private_file(self.root / name)
        require(sha(self.root / "config.json") == self.seal and sha(self.root / "worker.py") == self.cfg["workerSha256"] and
                (self.root / "OWNER").read_text() == self.cfg["owner"] + "\n" and
                sha(Path(self.cfg["argv"][0])) == self.cfg["binarySha256"], "observation source/config/server changed")
        require(str(Path("/run/current-system").resolve()) == self.cfg["systemClosure"] and
                Path("/proc/sys/kernel/random/boot_id").read_text().strip() == self.cfg["bootId"], "observation boot/closure changed")

    def completion_readiness(self, saved):
        started = self.read("started.json")
        require(started.get("result") == "pass" and started.get("invocationId") == saved["invocationId"], "no positive original start")
        if memlock_mode(self.cfg) == "scoped-prlimit":
            ready = self.read("memlock-ready.json")
            require(ready.get("result") == "pass" and ready.get("invocationId") == saved["invocationId"] and
                    ready.get("process") == {k: saved[k] for k in ("pid", "startTicks", "cgroup")} and
                    ready.get("policy") == self.cfg["memlock"] and ready.get("before") == self.cfg["memlock"]["before"] and
                    ready.get("after") == [resource.RLIM_INFINITY] * 2, "no positive original memlock readiness")

    def wait_success(self):
        # Never hold the ownership lock while sleeping. Other exact stop callers
        # can cancel between observations; independent RuntimeMax is unchanged.
        while True:
            with ownership_lock(self.root):
                self.verify_observation_sources()
                prepared = self.read("prepared.json")
                original_deadline = prepared["preparedAt"] + self.cfg["leaseSeconds"]
                deadline = original_deadline - self.cfg["stopSeconds"]
                remaining = deadline - time.monotonic()
                require(remaining > 0 and not (self.root / "canceled.json").exists() and
                        not (self.root / "stopped.json").exists(), "completion deadline expired or canceled/stopped")
                now = self.show(timeout=min(5, remaining))
                try:
                    saved = self.identify(now)  # Collected state cannot complete.
                except FileNotFoundError:
                    # A short-lived client can exit after systemd reports its
                    # live MainPID but before /proc is read. Re-observe the
                    # exact same unit once; identify() still requires the
                    # original invocation, terminal history, and empty cgroup.
                    # Any replacement, live mismatch, or collected unit
                    # remains a hard failure.
                    now = self.show(timeout=min(5, remaining))
                    saved = self.identify(now)
                self.completion_readiness(saved)
                require(now.get("ActiveState") == "active" and now.get("SubState") in ("running", "exited"), "client did not exit naturally")
                if now.get("MainPID") == "0":
                    require(now.get("SubState") == "exited" and now.get("Result") == "success" and
                            now.get("ExecMainCode") == "1" and now.get("ExecMainStatus") == "0" and
                            now.get("ExecMainPID") == str(saved["pid"]), "client natural exit0 history missing")
                    require(group_empty(saved["cgroup"]), "client descendants still live")
                    self.verify_observation_sources()
                    observed = time.monotonic()
                    require(observed < deadline and not (self.root / "canceled.json").exists(), "completion observed after deadline/cancel")
                    fields = {"result": "pass", "meaning": "natural-exit0-not-benchmark-pass", "invocationId": saved["invocationId"],
                              "process": {k: saved[k] for k in ("pid", "startTicks", "cgroup")}, "properties": now,
                              "originalDeadline": original_deadline, "completionDeadline": deadline, "observedAt": observed}
                    if (self.root / "completed.json").exists():
                        old = self.read("completed.json")
                        require(all(old.get(k) == v for k, v in fields.items() if k != "observedAt") and
                                type(old.get("observedAt")) in (int, float) and old["observedAt"] < deadline,
                                "immutable completion changed")
                        return old
                    return self.write("completed.json", **fields)
                require(now.get("SubState") == "running", "invalid live client state")
                remaining = deadline - time.monotonic()
                require(remaining > 0, "completion query exhausted deadline")
            time.sleep(min(.2, remaining))

    def journal_identity(self, now):
        saved = self.execution()
        if (self.root / "stopped.json").exists():
            self.verify_stopped(now)
        else:
            # Read-only diagnostic scope can include failed exit metadata that
            # is insufficient for cleanup/traffic PASS, but never a replacement.
            self.policy(now, self.read("start-attempted.json"))
            require(now.get("InvocationID") == saved["invocationId"], "journal invocation changed/collected without stop")
            if now.get("MainPID") == "0":
                require(now.get("ExecMainPID") == str(saved["pid"]) and now.get("ControlGroup") in ("", saved["cgroup"]), "journal terminal history changed")
                if now.get("ControlGroup") == "":
                    require(group_empty(saved["cgroup"]), "cleared journal group still live")
            else:
                require(now.get("MainPID") == str(saved["pid"]) and now.get("ControlGroup") == saved["cgroup"] and
                        process_identity(saved["pid"]) == {k: saved[k] for k in ("pid", "startTicks", "cgroup")}, "journal live process changed")
        return saved

    def journal(self):
        # Caller holds the short bounded export lock, not a lifetime wait lock.
        self.verify_observation_sources()
        before = self.show(timeout=5)
        saved = self.journal_identity(before)
        tool = str(Path(self.cfg["tools"]["systemctl"]).with_name("journalctl"))
        require(re.fullmatch(r"/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/journalctl", tool), "immutable journalctl sibling required")
        boot = self.cfg["bootId"].replace("-", "")
        argv = [tool, "--user", "--no-pager", "--all", "-o", "json", "_BOOT_ID=" + boot,
                "_SYSTEMD_INVOCATION_ID=" + saved["invocationId"], "+", "_BOOT_ID=" + boot,
                "USER_INVOCATION_ID=" + saved["invocationId"], "USER_UNIT=" + self.cfg["unit"]]
        self.write("journal-attempted.json", result="pending", invocationId=saved["invocationId"], argv=argv,
                   journalToolSha256=sha(Path(tool)), properties=before)
        try:
            capture = bounded_journal(argv)
        except Exception as failure:
            self.write("journal.json", result="failed", invocationId=saved["invocationId"],
                       meaning="combined-observed-journal-not-byte-exact-workload-streams", capture=None,
                       records=[], combinedObservedMessages=[], text="", propertiesBefore=before, propertiesAfter=None,
                       error="journal capture failed: " + str(failure))
            raise
        good = capture["exit"] == 0 and not capture["timedOut"] and capture["overflow"] is None
        error, records, messages = None, [], []
        try:
            require(good, "journal query failed/timed-out/overflowed")
            for line in base64.b64decode(capture["stdoutBase64"], validate=True).decode("utf-8").splitlines():
                row = json.loads(line)
                require(isinstance(row, dict) and row.get("_BOOT_ID") == boot and
                        (row.get("_SYSTEMD_INVOCATION_ID") == saved["invocationId"] or
                         row.get("USER_INVOCATION_ID") == saved["invocationId"] and row.get("USER_UNIT") == self.cfg["unit"]),
                        "foreign journal record")
                records.append(row)
                if row.get("_SYSTEMD_INVOCATION_ID") == saved["invocationId"]:
                    require(isinstance(row.get("MESSAGE"), str), "non-text workload journal message")
                    messages.append(row["MESSAGE"])
            after = self.show(timeout=5)
            require(self.journal_identity(after) == saved, "journal ownership changed during export")
            self.verify_observation_sources()
            require(sha(Path(tool)) == self.read("journal-attempted.json")["journalToolSha256"], "journal tool changed")
        except Exception as failure:
            good, error, after = False, str(failure), None
        receipt = self.write("journal.json", result="pass" if good else "failed", invocationId=saved["invocationId"],
                             meaning="combined-observed-journal-not-byte-exact-workload-streams", capture=capture,
                             records=records, combinedObservedMessages=messages, text="\n".join(messages) + ("\n" if messages else ""),
                             propertiesBefore=before, propertiesAfter=after, error=error)
        require(good, "journal evidence incomplete: " + str(error))
        return receipt

    def verify_stopped(self, now):
        saved = self.read("stopped.json")
        require(saved.get("result") == "pass", "no positive stop")
        if saved.get("neverStarted"):
            require(not (self.root / "start-attempted.json").exists() and now["LoadState"] == "not-found", "never-started proof changed")
        else:
            intent, executed = self.stop_intent()
            require(saved["invocationId"] == executed["invocationId"] and saved["cgroup"] == executed["cgroup"], "stopped identity changed")
            require(saved.get("before") == intent["properties"], "saved stop intent changed")
            self.stopped_state(now, executed)
        self.read("canceled.json")
        return saved

    def stop(self):
        # Under the same lock as start; cancellation remains even when a query
        # fails, so a delayed caller cannot restart the owned service.
        if not (self.root / "canceled.json").exists():
            self.write("canceled.json", result="pass")
        now = self.show()
        if (self.root / "stopped.json").exists():
            return self.verify_stopped(now)
        if not (self.root / "start-attempted.json").exists():
            require(now["LoadState"] == "not-found", "unexpected unit before start")
            return self.write("stopped.json", result="pass", neverStarted=True)
        if (self.root / "before-stop.json").exists():
            intent, saved = self.stop_intent()
            # A lost stop reply is recoverable only from the immutable exact
            # preceding intent plus current stopped state and empty hierarchy.
            if now["LoadState"] == "not-found" or now.get("MainPID") == "0" and now.get("ActiveState") in ("inactive", "failed"):
                self.stopped_state(now, saved)
                return self.write("stopped.json", result="pass", neverStarted=False, invocationId=saved["invocationId"],
                                  cgroup=saved["cgroup"], before=intent["properties"], after=now, recoveredStopReply=True)
            self.identify(now)  # No stop of a replacement or uncertain process.
        else:
            saved = self.identify(now)  # Unknown/collected without intent fails.
            intent = self.write("before-stop.json", intent="stop-exact-unit", properties=now, invocationId=saved["invocationId"],
                                cgroup=saved["cgroup"], workerArgv=self.argv(), serverArgv=self.cfg["argv"])
        self.tool("systemctl", "--user", "stop", self.cfg["unit"], timeout=self.cfg["stopSeconds"] + 20)
        after = self.show()
        self.stopped_state(after, saved)
        return self.write("stopped.json", result="pass", neverStarted=False, invocationId=saved["invocationId"],
                          cgroup=saved["cgroup"], before=intent["properties"], after=after)

    def execute(self):
        require(not (self.root / "canceled.json").exists(), "canceled before worker execution")
        attempt = self.read("start-attempted.json")
        prepared = self.read("prepared.json")
        require(time.monotonic() + attempt["runtimeSeconds"] <= prepared["preparedAt"] + self.cfg["leaseSeconds"], "original lease expired or activation delayed")
        now = self.show()
        self.policy(now, attempt)
        invocation = os.environ.get("INVOCATION_ID", "")
        require(re.fullmatch(r"[0-9a-f]{32}", invocation) and now.get("InvocationID") == invocation, "not the declared service invocation")
        own = process_identity(os.getpid())
        require(now.get("MainPID") == str(own["pid"]) and now.get("ControlGroup") == own["cgroup"], "worker outside declared unit")
        require(not (self.root / "canceled.json").exists(), "canceled before exec")
        self.write("executing.json", result="pass", invocationId=invocation, serverArgv=self.cfg["argv"],
                   binarySha256=self.cfg["binarySha256"], **own)
        if memlock_mode(self.cfg) == "scoped-prlimit":
            self.scoped_memlock(own, invocation, attempt, prepared)
            self.memlock_guard(own, invocation, attempt, prepared)
        env = {"PATH": "/run/current-system/sw/bin:/usr/bin:/bin", "LANG": "C", "INVOCATION_ID": invocation}
        os.chdir("/")
        os.execve(self.cfg["argv"][0], self.cfg["argv"], env)

    def memlock_guard(self, own, invocation, attempt, prepared):
        require(not (self.root / "canceled.json").exists(), "canceled during memlock preparation")
        require(time.monotonic() + attempt["runtimeSeconds"] <= prepared["preparedAt"] + self.cfg["leaseSeconds"], "memlock preparation exceeded original deadline")
        require(os.getpid() == own["pid"] and process_identity(os.getpid()) == own, "memlock worker identity changed")
        now = self.show()
        self.policy(now, attempt)
        require(now.get("InvocationID") == invocation and now.get("MainPID") == str(own["pid"]) and
                now.get("ControlGroup") == own["cgroup"], "memlock worker left exact unit")
        require(sha(self.root / "worker.py") == self.cfg["workerSha256"] and sha(self.root / "config.json") == self.seal and
                sha(Path(self.cfg["argv"][0])) == self.cfg["binarySha256"], "memlock source/config/server seal changed")
        require(str(Path("/run/current-system").resolve()) == self.cfg["systemClosure"] and
                Path("/proc/sys/kernel/random/boot_id").read_text().strip() == self.cfg["bootId"], "memlock boot/closure changed")
        require(not (self.root / "canceled.json").exists() and
                time.monotonic() + attempt["runtimeSeconds"] <= prepared["preparedAt"] + self.cfg["leaseSeconds"],
                "memlock guard query exhausted original deadline or was canceled")

    def scoped_memlock(self, own, invocation, attempt, prepared):
        policy = self.cfg["memlock"]
        before = list(resource.getrlimit(resource.RLIMIT_MEMLOCK))
        require(before == policy["before"], "unexpected existing memlock limits")
        tools = verify_memlock_tools(policy)
        self.memlock_guard(own, invocation, attempt, prepared)
        argv = [policy["sudo"]["path"], "-n", policy["prlimit"]["path"], "--pid", str(own["pid"]), "--memlock=unlimited"]
        self.write("memlock-attempted.json", result="pending", invocationId=invocation, process=own, policy=policy,
                   before=before, argv=argv, tools=tools)
        self.memlock_guard(own, invocation, attempt, prepared)
        command(argv, timeout=5)  # Descendants inherit the exact bounded service cgroup.
        self.memlock_guard(own, invocation, attempt, prepared)
        require(verify_memlock_tools(policy) == tools, "memlock tools changed during operation")
        after = list(resource.getrlimit(resource.RLIMIT_MEMLOCK))
        require(after == [resource.RLIM_INFINITY, resource.RLIM_INFINITY], "memlock was not made unlimited")
        self.memlock_guard(own, invocation, attempt, prepared)
        self.write("memlock-ready.json", result="pass", invocationId=invocation, process=own,
                   policy=policy, before=before, after=after, tools=tools)


def load(root, seal):
    require(sys.flags.isolated == 1 and sys.flags.optimize == 0, "invoke with Python -I without optimization")
    require(root.is_absolute() and str(root.resolve()) == str(root), "state path not canonical")
    info = root.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, "private owned state directory required")
    for name in ("config.json", "worker.py", "OWNER"):
        private_file(root / name)
    require(re.fullmatch(r"[0-9a-f]{64}", seal) and sha(root / "config.json") == seal, "config seal changed")
    cfg = json.loads((root / "config.json").read_text())
    validate(cfg, root)
    require((root / "OWNER").read_text() == cfg["owner"] + "\n", "owner changed")
    require(sha(root / "worker.py") == cfg["workerSha256"] and Path(__file__).resolve() == root / "worker.py", "worker source changed")
    require(command([cfg["tools"]["hostname"]]).stdout.strip() == cfg["hostname"], "wrong node")
    require(str(Path("/run/current-system").resolve()) == cfg["systemClosure"], "system closure changed")
    require(Path("/proc/sys/kernel/random/boot_id").read_text().strip() == cfg["bootId"], "boot changed")
    require(sha(Path(cfg["argv"][0])) == cfg["binarySha256"], "server binary changed")
    return Server(root, cfg, seal)


def main():
    require(len(sys.argv) == 4 and sys.argv[1] in ("prepare", "start", "inspect", "stop", "exec", "wait-success", "journal"), "usage: ACTION STATE CONFIG_SHA256")
    server = load(Path(sys.argv[2]), sys.argv[3])
    if sys.argv[1] == "exec":
        server.execute()  # Must not wait on the parent's start lock.
        return
    if sys.argv[1] == "wait-success":
        print(json.dumps(server.wait_success(), sort_keys=True))
        return
    with ownership_lock(server.root):
        print(json.dumps(getattr(server, sys.argv[1])(), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"result": "failed", "error": str(error)}), file=sys.stderr)
        sys.exit(1)
