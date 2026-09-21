"""Private, immutable records for the finite Deuces-direct network guard.

No host discovery, network operations or service launches in this module.
"""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time


def require(ok, why):
    if not ok:
        raise RuntimeError(why)


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_file(path, maximum=1048576):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077,
                "private regular owned input required")
        require(info.st_size <= maximum, "oversized input")
        data = stream.read(maximum + 1)
        require(len(data) <= maximum, "input grew")
        return data


def directory(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve(strict=True) == path, "canonical state directory required")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
            "private owned state directory required")
    return path


def publish(root, name, data):
    root = directory(root)
    require(re.fullmatch(r"[a-zA-Z0-9._-]+", name) is not None, "receipt name")
    pending = root / (".pending-" + os.urandom(16).hex())
    fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.link(pending, root / name, follow_symlinks=False)
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        pending.unlink()


class State:
    def __init__(self, root, seal):
        self.root = directory(root)
        require(re.fullmatch("[a-f0-9]{64}", seal) is not None, "config seal")
        raw = read_file(self.root / "config.json")
        require(digest(raw) == seal, "state config changed")
        self.config = json.loads(raw)
        self.seal = seal
        self.owner = self.config["owner"]
        require(re.fullmatch("[a-f0-9]{64}", self.owner) is not None and
                read_file(self.root / "OWNER") == (self.owner + "\n").encode(), "state owner mismatch")

    def sources(self):
        require(digest(read_file(self.root / 'config.json')) == self.seal and
                read_file(self.root / 'OWNER') == (self.owner + '\n').encode(), 'state identity changed')
        expected = self.config["sources"]
        require(isinstance(expected, dict) and expected, "source inventory missing")
        for name, seal in expected.items():
            require(re.fullmatch(r"[a-zA-Z0-9._-]+", name) is not None and name not in ("config.json", "OWNER"), "source basename")
            require(re.fullmatch("[a-f0-9]{64}", seal) is not None and digest(read_file(self.root / name)) == seal,
                    "guard source changed: " + name)

    def read(self, name):
        value = json.loads(read_file(self.root / name))
        require(value.get("owner") == self.owner and value.get("configSha256") == self.seal,
                "foreign receipt: " + name)
        return value

    def write(self, name, **fields):
        require("owner" not in fields and "configSha256" not in fields, "reserved identity fields")
        value = dict(owner=self.owner, configSha256=self.seal, **fields)
        publish(self.root, name, encode(value))
        return value

    def intent(self, name, argv):
        require(isinstance(argv, list) and argv and all(isinstance(x, str) and x and "\0" not in x for x in argv), "fixed argv required")
        return self.write(name + "-intent.json", argv=argv)

    @contextmanager
    def lock(self, seconds=5):
        require(type(seconds) is int and 1 <= seconds <= 240, "bounded state lock")
        fd = os.open(self.root / "guard.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600,
                    "lock identity/permissions")
            until = time.monotonic() + seconds
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    require(time.monotonic() < until, "guard lock busy; no network mutation")
                    time.sleep(0.05)
            self.sources()
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)


def cgroup_empty(path):
    require(isinstance(path, str) and path.startswith("/user.slice/") and ".." not in Path(path).parts,
            "recorded user cgroup required")
    base = Path('/sys/fs/cgroup')
    require(base.is_dir() and not base.is_symlink() and base.resolve(strict=True)==base,
            'real cgroup root required before accepting disappearance')
    mounts=[]
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        left,separator,right=line.partition(' - ')
        fields=left.split()
        if separator and len(fields)>=6 and fields[4]=='/sys/fs/cgroup':mounts.append((fields,right.split()))
    require(len(mounts)==1 and mounts[0][0][3]=='/' and mounts[0][1] and mounts[0][1][0]=='cgroup2','expected cgroup-v2 mount absent/changed')
    controllers=base/'cgroup.controllers'
    require(controllers.is_file() and not controllers.is_symlink() and controllers.read_text().strip(),
            'root cgroup controllers unreadable/empty')
    root = Path("/sys/fs/cgroup" + path)
    if not root.exists():
        return True  # Requires separate positive exact invocation terminal proof.
    require(root.is_dir() and not root.is_symlink(), "cgroup root identity")
    first = root / "cgroup.procs"
    require(first.is_file() and not first.is_symlink(), "missing root cgroup.procs")
    require(not first.read_text().strip(), "live root cgroup")
    def onerror(error): raise error
    for current, children, files in os.walk(root, onerror=onerror, followlinks=False):
        group = Path(current)
        require(not group.is_symlink() and "cgroup.procs" in files, "unreadable/changed descendant")
        require(not any((group / child).is_symlink() for child in children), 'indirect descendant cgroup')
        procs = group / "cgroup.procs"
        require(not procs.is_symlink() and not procs.read_text().strip(), "live descendant cgroup")
    return True
