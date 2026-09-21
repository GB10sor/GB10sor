#!/usr/bin/env python3
"""Finite-lease, exact-owned model container lifecycle.

Integrated through the opt-in finite adapter; full model qualification pending.
No network configuration or firewall mutation.
Adapted from the separately qualified private single-rail worker; model argv
and mounts are an externally sealed contract, not a new inference recipe.
"""
import fcntl
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import uuid

CLEANUP_STOP_SECONDS = 30


def require(ok, why):
    if not ok:
        raise RuntimeError(why)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def command(argv, check=True, timeout=30):
    # Never inherit an inaccessible/deleted caller cwd or shell startup files.
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout,
                            cwd="/", env={"PATH": "/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin",
                                         **{k: os.environ[k] for k in ("HOME", "USER", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS") if k in os.environ}})
    if check:
        require(result.returncode == 0, f"command failed ({result.returncode}): {argv[0]}: {result.stderr}")
    return result


def atomic(root, name, value):
    temporary = root / (name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("x") as output:
        os.chmod(temporary, 0o600)
        json.dump(value, output, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, root / name)


def properties(text):
    result = {}
    for line in text.splitlines():
        require("=" in line, "malformed systemd property")
        key, value = line.split("=", 1)
        require(key not in result, "duplicate systemd property")
        result[key] = value
    return result


def exact_exec_start(value, argv):
    match = re.fullmatch(r"\{ path=([^;]+) ; argv\[\]=([^;]+) ; ignore_errors=no ; ([^{}]*) \}", value)
    require(match is not None, "not one exact ExecStart record")
    require(match[1] == argv[0] and match[2] == " ".join(argv), "cleanup ExecStart changed")


def time_usec(value):
    """Parse finite systemctl duration formatting, not a guessed raw integer."""
    require(isinstance(value, str) and 0 < len(value) <= 80, "missing cleanup time bound")
    units = {"min": 60000000, "s": 1000000, "ms": 1000, "us": 1}
    total = Fraction(0)
    for part in value.split(" "):
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(min|ms|us|s)", part)
        require(match is not None, "unrecognized/unbounded cleanup duration")
        total += Fraction(match[1]) * units[match[2]]
    require(total.denominator == 1, "sub-microsecond cleanup duration")
    return int(total)


def validate_config(cfg, root):
    keys = {"version", "owner", "rank", "name", "hostname", "systemClosure", "imageRef", "imageId", "imageLayersSha256",
            "createArgv", "mounts", "entrypoint", "args", "leaseSeconds", "cleanupSeconds", "stopSeconds", "python", "tools", "sources"}
    require(set(cfg) == keys and cfg["version"] == 1, "configuration schema")
    require(re.fullmatch(r"gb10sor-owned-model\.[0-9a-f]{32}-rank[01]", root.name), "state basename")
    require(type(cfg["rank"]) is int and cfg["rank"] in (0, 1) and root.name.endswith(f'rank{cfg["rank"]}'), "rank")
    require(re.fullmatch(r"[0-9a-f]{64}", cfg["owner"]), "owner token")
    require(re.fullmatch(r"gb10sor-(vllm|sglang)-[A-Za-z0-9-]+-rank[01]", cfg["name"]), "container name")
    require(cfg["name"].endswith(f'rank{cfg["rank"]}'), "container rank")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*", cfg["hostname"]), "hostname")
    require(re.fullmatch(r"/nix/store/[a-z0-9]+-nixos-system-[A-Za-z0-9.+_-]+", cfg["systemClosure"]), "NixOS closure")
    for key in ("imageId", "imageLayersSha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", cfg[key]), key)
    for key, low, high in (("leaseSeconds", 180, 43200), ("cleanupSeconds", 120, 300), ("stopSeconds", 1, 30)):
        require(type(cfg[key]) is int and low <= cfg[key] <= high, f"finite explicit {key} required")
    require(set(cfg["tools"]) == {"podman", "systemctl", "systemd-run", "journalctl", "hostname"}, "tool schema")
    for value in [cfg["python"], *cfg["tools"].values()]:
        require(isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9._/+:-]+", value), "absolute tool path")
    require(set(cfg["sources"]) == {"worker.py"} and re.fullmatch(r"[0-9a-f]{64}", cfg["sources"]["worker.py"]), "worker source seal")
    argv = cfg["createArgv"]
    require(isinstance(argv, list) and len(argv) > 4 and all(isinstance(x, str) and x and not any(c in x for c in "\0\n\r") for x in argv), "argv schema")
    require(argv[:2] == [cfg["tools"]["podman"], "create"] and argv.count("--name") == 1 and argv[argv.index("--name") + 1] == cfg["name"], "create/name argv")
    require("--pull=never" in argv and not any(x.split("=", 1)[0] in ("--privileged", "--rm", "-d") for x in argv), "bounded explicit create policy")
    require(not any("gb10sor." in arg for arg in argv), "owner labels reserved")
    require(isinstance(cfg["entrypoint"], str) and cfg["entrypoint"] and isinstance(cfg["args"], list) and all(isinstance(x, str) for x in cfg["args"]), "process argv")
    require(isinstance(cfg["mounts"], list) and cfg["mounts"], "mount contract required")
    destinations = []
    for mount in cfg["mounts"]:
        require(set(mount) == {"source", "destination", "readonly"} and mount["readonly"] is True, "read-only bind contract")
        for field in ("source", "destination"):
            value = mount[field]
            require(isinstance(value, str) and re.fullmatch(r"/[A-Za-z0-9._/@+-]+", value) and ".." not in Path(value).parts and value != "/", "safe mount path")
        destinations.append(mount["destination"])
    require(len(destinations) == len(set(destinations)), "duplicate mount destination")
    require(isinstance(cfg["imageRef"], str) and re.fullmatch(r"(?:[A-Za-z0-9._/:-]+@sha256:[0-9a-f]{64}|[0-9a-f]{64}|localhost/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+)", cfg["imageRef"]), "pinned runtime reference")
    require(argv.count(cfg["imageRef"]) == 1, "image argv boundary")
    position = argv.index(cfg["imageRef"])
    options = argv[2:position]
    require(options.count("--entrypoint") == 1 and options[options.index("--entrypoint") + 1] == cfg["entrypoint"] and argv[position + 1:] == cfg["args"], "declared process argv differs")
    require(not any(x.startswith("--volume") or x.startswith("--mount") for x in options), "binds must use explicit -v form")
    binds = [options[i + 1] for i, arg in enumerate(options) if arg == "-v" and i + 1 < len(options)]
    expected = [m["source"] + ":" + m["destination"] + ":ro" for m in cfg["mounts"]]
    require(sorted(binds) == sorted(expected), "create mounts differ from sealed read-only contract")


class Owned:
    def __init__(self, root, cfg, seal):
        self.root, self.cfg, self.seal = Path(root), cfg, seal
        self.timer = self.root.name + "-cleanup"

    def tool(self, name, *args, **kwargs):
        return command([self.cfg["tools"][name], *args], **kwargs)

    def write(self, filename, **fields):
        value = {"owner": self.cfg["owner"], "configSha256": self.seal, **fields}
        atomic(self.root, filename, value)
        return value

    def read(self, name):
        path = self.root / name
        require(path.is_file() and not path.is_symlink(), "missing positive receipt: " + name)
        value = json.loads(path.read_text())
        require(value["owner"] == self.cfg["owner"] and value["configSha256"] == self.seal, "receipt identity changed")
        return value

    def show(self, suffix):
        result = self.tool("systemctl", "--user", "show", self.timer + suffix,
                           "-p", "LoadState", "-p", "Id", "-p", "Description", "-p", "InvocationID",
                           "-p", "ActiveState", "-p", "SubState", "-p", "MainPID", "-p", "Result", "-p", "ExecMainStatus", "-p", "ExecStart",
                           "-p", "Type", "-p", "KillMode", "-p", "TimeoutStartUSec", "-p", "TimeoutStopUSec",
                           "-p", "Restart", "-p", "WorkingDirectory", check=False)
        require(result.returncode in (0, 4), "systemd query failed")
        value = properties(result.stdout)
        require(value.get("LoadState") in ("loaded", "not-found"), "unknown unit load state")
        require(result.returncode == 0 or value["LoadState"] == "not-found", "unexpected systemd error")
        return value

    def exists(self, identifier):
        result = self.tool("podman", "container", "exists", identifier, check=False)
        require(result.returncode in (0, 1), "container existence query failed")
        return result.returncode == 0

    def create_argv(self):
        labels = ["--label", "gb10sor.owner=" + self.cfg["owner"], "--label", "gb10sor.config=" + self.seal,
                  "--label", "gb10sor.rank=" + str(self.cfg["rank"])]
        return self.cfg["createArgv"][:2] + labels + self.cfg["createArgv"][2:]

    def cleanup_argv(self):
        return [self.cfg["python"], "-I", str(self.root / "worker.py"), "cleanup", str(self.root), self.seal]

    def verify_service_policy(self, service):
        require(service.get("LoadState") == "loaded" and service.get("Id") == self.timer + ".service" and service.get("Description") == self.cfg["owner"], "cleanup service identity")
        require(service.get("Type") == "oneshot" and service.get("KillMode") == "control-group", "cleanup lifecycle policy changed")
        require(service.get("Restart") == "no" and service.get("WorkingDirectory") == "/", "cleanup restart/cwd policy changed")
        require(time_usec(service.get("TimeoutStartUSec")) == self.cfg["cleanupSeconds"] * 1000000, "cleanup start time bound changed")
        require(time_usec(service.get("TimeoutStopUSec")) == CLEANUP_STOP_SECONDS * 1000000, "cleanup stop time bound changed")
        exact_exec_start(service.get("ExecStart", ""), self.cleanup_argv())

    def check_timer(self):
        saved = self.read("armed.json")
        self.verify_service_policy(saved["service"])
        require(time.monotonic() + 120 < saved["armedAt"] + self.cfg["leaseSeconds"], "insufficient finite lease remaining")
        now = self.show(".timer")
        require(now["LoadState"] == "loaded" and now.get("ActiveState") == "active", "cleanup timer not active")
        require(all(now.get(k) == saved["timer"][k] for k in ("Id", "Description", "InvocationID")), "timer identity changed")
        service = self.show(".service")
        self.verify_service_policy(service)
        require(service.get("ActiveState") == "inactive" and service.get("MainPID") == "0", "cleanup timer already firing")
        require(time.monotonic() + 120 < saved["armedAt"] + self.cfg["leaseSeconds"], "lease expired during timer checks")
        return now

    def prepare(self):
        require(not (self.root / "prepared.json").exists(), "already prepared")
        require(not self.exists(self.cfg["name"]), "container collision")
        for suffix in (".timer", ".service"):
            require(self.show(suffix)["LoadState"] == "not-found", "unit collision")
        return self.write("prepared.json", result="pass", name=self.cfg["name"], createArgvSha256=digest(self.create_argv()))

    def arm(self):
        self.read("prepared.json")
        require(not (self.root / "canceled.json").exists() and not (self.root / "arm-attempted.json").exists(), "arm canceled/already attempted")
        for suffix in (".timer", ".service"):
            require(self.show(suffix)["LoadState"] == "not-found", "unit collision")
        armed_at = time.monotonic()
        self.write("arm-attempted.json", argv=self.cleanup_argv(), armedAt=armed_at)
        self.tool("systemd-run", "--user", "--unit=" + self.timer, "--description=" + self.cfg["owner"],
                  "--on-active=" + str(self.cfg["leaseSeconds"]) + "s", "--timer-property=AccuracySec=1s",
                  "--property=Type=oneshot", "--property=TimeoutStartSec=" + str(self.cfg["cleanupSeconds"]) + "s",
                  "--property=TimeoutStopSec=" + str(CLEANUP_STOP_SECONDS) + "s", "--property=KillMode=control-group",
                  "--property=Restart=no", "--property=WorkingDirectory=/",
                  "--setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin", *self.cleanup_argv())
        current = self.show(".timer")
        require(current.get("Id") == self.timer + ".timer" and current.get("Description") == self.cfg["owner"] and re.fullmatch(r"[0-9a-f]{32}", current.get("InvocationID", "")), "timer arm identity")
        service = self.show(".service")
        self.verify_service_policy(service)
        require(service.get("ActiveState") == "inactive" and service.get("MainPID") == "0", "cleanup service already executing at arm")
        self.write("armed.json", result="pass", timer=current, service=service, armedAt=armed_at)
        self.check_timer()
        return self.read("armed.json")

    def process(self, pid):
        require(type(pid) is int and pid > 0, "PID invalid")
        path = Path("/proc") / str(pid)
        require(path.stat().st_uid == os.getuid(), "PID owner changed")
        ticks = (path / "stat").read_text().rsplit(")", 1)[1].split()[19]
        lines = (path / "cgroup").read_text().splitlines()
        require(len(lines) == 1 and lines[0].startswith("0::/user.slice/"), "unexpected cgroup layout")
        group = lines[0][3:]
        require(".." not in Path(group).parts, "unsafe cgroup")
        return {"pid": pid, "startTicks": ticks, "cgroup": group}

    def inspect(self):
        self.read("prepared.json")
        receipt = self.read("cid.json") if (self.root / "cid.json").exists() else None
        identifier = receipt["cid"] if receipt else self.cfg["name"]
        if not self.exists(identifier):
            if receipt:
                removed = self.read("removed.json")
                require(removed["cid"] == identifier and removed["result"] == "pass", "missing saved container without positive removal")
                require(not self.exists(self.cfg["name"]), "name replaced after removal")
            else:
                require(not (self.root / "create-attempted.json").exists(), "attempted create lacks positive CID/removal proof")
            return None
        data = json.loads(self.tool("podman", "inspect", identifier).stdout)[0]
        cid = data["Id"]
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid CID")
        require(not receipt or receipt["cid"] == cid, "CID changed")
        require(data["Name"] == self.cfg["name"] and data["Image"] == self.cfg["imageId"], "name/image changed")
        labels = data["Config"]["Labels"]
        require(labels.get("gb10sor.owner") == self.cfg["owner"] and labels.get("gb10sor.config") == self.seal and labels.get("gb10sor.rank") == str(self.cfg["rank"]), "owner labels changed")
        require(data["Config"].get("CreateCommand") == self.create_argv(), "create argv changed")
        require(data["Path"] == self.cfg["entrypoint"] and data["Args"] == self.cfg["args"], "container process argv changed")
        mounts = {m["Destination"]: m for m in data["Mounts"]}
        require(len(mounts) == len(data["Mounts"]) == len(self.cfg["mounts"]), "mount set changed")
        for expected in self.cfg["mounts"]:
            actual = mounts.get(expected["destination"], {})
            require(actual.get("Source") == expected["source"] and actual.get("RW") is False and actual.get("Type") == "bind", "read-only mount changed")
        if not receipt:
            self.read("create-attempted.json")
            self.write("cid.json", cid=cid, createArgvSha256=digest(self.create_argv()))
        if data["State"]["Pid"]:
            first = self.process(data["State"]["Pid"])
            require(cid in first["cgroup"], "cgroup does not identify CID")
            second = json.loads(self.tool("podman", "inspect", cid).stdout)[0]
            require(second["Id"] == cid and second["State"]["Pid"] == first["pid"] and self.process(first["pid"]) == first, "PID/cgroup changed during inspect")
            if (self.root / "process.json").exists():
                old = self.read("process.json")
                require(all(old.get(k) == v for k, v in first.items()), "process identity changed")
            self.write("process.json", **first)
        return data

    def empty(self):
        if not (self.root / "process.json").exists():
            require(not (self.root / "start-attempted.json").exists(), "started container lacks cgroup proof")
            return True
        group = self.read("process.json")["cgroup"]
        require(group.startswith("/user.slice/") and ".." not in Path(group).parts and self.read("cid.json")["cid"] in group, "unsafe saved cgroup")
        path = Path("/sys/fs/cgroup" + group)
        if not path.exists():
            return True
        require(path.is_dir() and not path.is_symlink() and (path / "cgroup.procs").is_file(), "missing root cgroup.procs")
        require(not (path / "cgroup.procs").read_text().strip(), "live root cgroup")
        def walk_error(error):
            raise error
        for directory, children, _files in os.walk(path, followlinks=False, onerror=walk_error):
            for child in children:
                require(not (Path(directory) / child).is_symlink(), "indirect descendant cgroup")
            member = Path(directory) / "cgroup.procs"
            require(member.is_file() and not member.is_symlink() and not member.read_text().strip(), "missing/unreadable/live descendant cgroup")
        return True

    def create(self):
        self.read("prepared.json")
        self.check_timer()
        require(not (self.root / "canceled.json").exists() and not (self.root / "create-attempted.json").exists(), "create canceled/already attempted")
        require(not self.exists(self.cfg["name"]), "container collision")
        for mount in self.cfg["mounts"]:
            path = Path(mount["source"])
            require(path.exists() and not path.is_symlink() and path.resolve() == path, "bind source missing or indirect")
        image = json.loads(self.tool("podman", "image", "inspect", self.cfg["imageId"]).stdout)[0]
        require(image["Id"] == self.cfg["imageId"] and image["Architecture"] == "arm64", "runtime image changed")
        layers = hashlib.sha256((json.dumps(image["RootFS"]["Layers"], separators=(",", ":")) + "\n").encode()).hexdigest()
        require(layers == self.cfg["imageLayersSha256"], "runtime layers changed")
        self.check_timer()
        self.write("create-attempted.json", argv=self.create_argv(), imageId=image["Id"], layers=layers)
        cid = self.tool("podman", *self.create_argv()[1:]).stdout.strip()
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "create response missing CID")
        self.write("cid.json", cid=cid, createArgvSha256=digest(self.create_argv()))
        data = self.inspect()
        require(data is not None and not data["State"]["Running"] and data["State"]["Pid"] == 0, "create unexpectedly running")
        return self.write("created.json", result="pass", cid=cid)

    def start(self):
        self.check_timer()
        require(not (self.root / "canceled.json").exists() and not (self.root / "start-attempted.json").exists(), "start canceled/already attempted")
        created = self.read("created.json")
        data = self.inspect()
        require(data is not None and data["Id"] == created["cid"] and not data["State"]["Running"], "created container changed")
        self.check_timer()
        self.write("start-attempted.json", cid=data["Id"])
        self.tool("podman", "start", data["Id"])
        data = self.inspect()
        require(data is not None and data["State"]["Running"] and (self.root / "process.json").exists(), "start process unverified")
        return self.write("started.json", result="pass", cid=data["Id"])

    def cleanup(self):
        self.read("prepared.json")
        self.write("canceled.json", result="canceled")
        errors = []
        try:
            data = self.inspect()
            if data:
                cid = data["Id"]
                if data["State"]["Running"]:
                    self.tool("podman", "stop", "--time", str(self.cfg["stopSeconds"]), cid,
                              timeout=self.cfg["stopSeconds"] + 30)
                final = self.inspect()
                require(final is not None and not final["State"]["Running"] and final["State"]["Pid"] == 0, "container did not stop")
                self.empty()
                self.write("remove-attempted.json", cid=cid, final=final)
                self.tool("podman", "rm", cid)
                require(not self.exists(cid) and not self.exists(self.cfg["name"]), "removal unverified")
                self.write("removed.json", cid=cid, result="pass")
            self.empty()
        except Exception as exc:
            errors.append(str(exc))
        process = self.process(os.getpid())
        process["invocationId"] = os.environ.get("INVOCATION_ID", "")
        result = self.write("cleanup.json", result="failed" if errors else "pass", errors=errors, process=process)
        print(json.dumps(result), flush=True)  # Exact application journal correlation.
        require(not errors, "owned cleanup failed: " + repr(errors))
        return result

    def disarm(self):
        complete = self.read("cleanup.json")
        require(complete["result"] == "pass" and not complete["errors"], "cleanup not positive")
        require(self.inspect() is None and self.empty(), "resources remain")
        saved = self.read("armed.json")
        self.verify_service_policy(saved["service"])
        require(saved["timer"].get("Id") == self.timer + ".timer" and saved["timer"].get("Description") == self.cfg["owner"] and re.fullmatch(r"[0-9a-f]{32}", saved["timer"].get("InvocationID", "")), "saved timer identity missing")
        current, service = self.show(".timer"), self.show(".service")
        if (self.root / "disarmed.json").exists():
            previous = self.read("disarmed.json")
            require(previous["result"] == "pass" and previous["timer"] == saved["timer"], "disarm receipt changed")
            require(current.get("ActiveState") == "inactive" and service.get("MainPID") == "0" and service.get("ActiveState") == "inactive", "previous disarm no longer idle")
            if current["LoadState"] == "loaded":
                require(current.get("Id") == self.timer + ".timer" and current.get("Description") == self.cfg["owner"] and current.get("InvocationID") in ("", saved["timer"]["InvocationID"]), "timer replaced after disarm")
            if service["LoadState"] == "loaded":
                self.verify_service_policy(service)
                require(service.get("Description") == self.cfg["owner"] and service.get("Result") == "success" and service.get("ExecMainStatus") == "0", "cleanup service replaced/failed after disarm")
                exact_exec_start(service.get("ExecStart", ""), self.cleanup_argv())
            return previous
        if current["LoadState"] == "loaded":
            require(all(current.get(k) == saved["timer"][k] for k in ("Id", "Description", "InvocationID")), "timer replaced")
            require(service.get("MainPID") == "0" and service.get("ActiveState") == "inactive", "cleanup service still executing")
            require(service.get("Description") == self.cfg["owner"] and service.get("Result") == "success" and service.get("ExecMainStatus") == "0", "cleanup service failed/replaced")
            self.verify_service_policy(service)
            exact_exec_start(service.get("ExecStart", ""), self.cleanup_argv())
            self.write("disarm-attempted.json", timer=current)
            self.tool("systemctl", "--user", "stop", self.timer + ".timer")
            after = self.show(".timer")
            require(after.get("ActiveState") == "inactive" and after.get("MainPID", "0") == "0", "timer remains active")
            if after["LoadState"] == "loaded":
                require(after.get("Id") == self.timer + ".timer" and after.get("Description") == self.cfg["owner"] and after.get("InvocationID") in ("", saved["timer"]["InvocationID"]), "timer replaced during disarm")
            final_service = self.show(".service")
            require(final_service.get("MainPID") == "0" and final_service.get("ActiveState") == "inactive", "cleanup service changed during disarm")
            if final_service["LoadState"] == "loaded":
                self.verify_service_policy(final_service)
                require(final_service.get("Description") == self.cfg["owner"] and final_service.get("Result") == "success" and final_service.get("ExecMainStatus") == "0", "cleanup service replaced/failed during disarm")
                exact_exec_start(final_service.get("ExecStart", ""), self.cleanup_argv())
        else:
            invocation = complete["process"]["invocationId"]
            require(re.fullmatch(r"[0-9a-f]{32}", invocation), "collected timer lacks positive invocation")
            require(complete["process"]["cgroup"].endswith("/" + self.timer + ".service"), "cleanup writer cgroup changed")
            require(service["LoadState"] == "not-found" and service.get("MainPID") == "0", "service not collected/idle")
            entries = [json.loads(x) for x in self.tool("journalctl", "--user", "--unit=" + self.timer + ".service", "-n", "200", "-o", "json", "--no-pager").stdout.splitlines()]
            application = [x for x in entries if x.get("_SYSTEMD_USER_UNIT") == self.timer + ".service"]
            require(application and application[-1].get("_SYSTEMD_INVOCATION_ID") == invocation and application[-1].get("_PID") == str(complete["process"]["pid"]), "collected timer journal identity")
            require(json.loads(application[-1]["MESSAGE"]) == complete, "collected timer lacks current completion")
            for entry in entries:
                require(entry.get("USER_INVOCATION_ID", invocation) == invocation and entry.get("RESULT", "success") == "success", "newer/failed timer invocation")
        return self.write("disarmed.json", result="pass", timer=saved["timer"])


def load(path, seal):
    root = Path(path)
    require(root.is_absolute() and root.resolve() == root and root.is_dir() and not root.is_symlink(), "state root path")
    require(root.stat().st_uid == os.getuid() and stat.S_IMODE(root.stat().st_mode) & 0o077 == 0, "private state directory permissions")
    for name in ("config.json", "OWNER", "worker.py"):
        path = root / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_uid == os.getuid() and stat.S_IMODE(path.stat().st_mode) & 0o022 == 0, "unsafe state input: " + name)
    require(re.fullmatch(r"[0-9a-f]{64}", seal), "config seal")
    raw = (root / "config.json").read_bytes()
    require(hashlib.sha256(raw).hexdigest() == seal, "config changed")
    cfg = json.loads(raw)
    validate_config(cfg, root)
    require((root / "OWNER").read_text().strip() == cfg["owner"], "state owner changed")
    require(Path(__file__).resolve() == root / "worker.py" and hashlib.sha256((root / "worker.py").read_bytes()).hexdigest() == cfg["sources"]["worker.py"], "worker source changed")
    require(command([cfg["tools"]["hostname"], "-s"]).stdout.strip() == cfg["hostname"] and os.readlink("/run/current-system") == cfg["systemClosure"], "node/closure changed")
    require(Path(sys.executable).resolve() == Path(cfg["python"]).resolve(), "Python runtime changed")
    return Owned(root, cfg, seal)


def main():
    require(sys.flags.isolated and not sys.flags.optimize, "Python -I required")
    action, path, seal = sys.argv[1:]
    require(action in ("prepare", "arm", "create", "start", "inspect", "cleanup", "disarm"), "unknown action")
    owned = load(path, seal)
    descriptor = os.open(owned.root / "control.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        info = os.fstat(lock.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) & 0o077 == 0, "unsafe control lock")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        result = getattr(owned, action)()
    if action != "cleanup":
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
