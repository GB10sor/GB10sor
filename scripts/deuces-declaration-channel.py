"""Local parent/child declaration handshake candidate; no remote operations.

The parent creates a fresh private channel and pins engine/source/node identity.
The child offers its declaration and MUST await acknowledgement before staging
any model resources. The parent's anchor, not a digest supplied after execution,
is the receipt consumer's input. This helper alone is not a durable supervisor.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def directory(root):
    root = Path(root)
    require(root.is_absolute(), "absolute channel required")
    for path in (root, *root.parents):
        require(not path.is_symlink(), "symlink channel ancestry")
    info = root.stat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "private owned channel required")
    return root


def read(root, name):
    path = directory(root) / name
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 1048576,
                "unsafe channel file")
        value = stream.read(1048577)
        require(len(value) <= 1048576, "oversize channel file")
        return value


def document(root, name):
    value = json.loads(read(root, name), object_pairs_hook=pairs)
    require(isinstance(value, dict), "object required")
    return value


def create(root, name, value):
    # Publish a complete file without replacing any previously claimed name.
    root = directory(root)
    temp = root / (".pending-" + os.urandom(16).hex())
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temp, root / name, follow_symlinks=False)
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temp.unlink()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def expected(value):
    require(set(value) == {"invocationOwner", "engine", "sourceSha256", "nodes"}, "expectation schema")
    require(re.fullmatch(r"[0-9a-f]{64}", value["invocationOwner"]), "parent owner required")
    require(value["engine"] in ("vllm", "sglang"), "engine")
    require(set(value["sourceSha256"]) == {"engine", "containerHelper", "hashHelper", "adapter"}
            and all(re.fullmatch(r"[0-9a-f]{64}", x) for x in value["sourceSha256"].values()), "source pins")
    nodes = value["nodes"]
    require(len(nodes) == 2 and {x["rank"] for x in nodes} == {0, 1}
            and len({x["node"] for x in nodes}) == 2 and len({x["host"] for x in nodes}) == 2,
            "two distinct parent-pinned nodes")
    require(all(set(x) == {"rank", "host", "node"} for x in nodes), "node schema")
    return value


def initialize(root, expectation):
    expected(expectation)
    Path(root).mkdir(mode=0o700)
    create(root, "expected.json", encoded(expectation))


def check(root, raw):
    exp = expected(document(root, "expected.json"))
    decl = json.loads(raw, object_pairs_hook=pairs)
    require(decl.get("schemaVersion") == 1 and decl.get("kind") == "gb10sor.deuces.resource-declaration", "declaration schema")
    require(all(decl.get(k) == exp[k] for k in ("invocationOwner", "engine", "sourceSha256")), "foreign owner/engine/source")
    require(re.fullmatch(r"gb10sor-" + exp["engine"] + r"-[A-Za-z0-9-]+", decl.get("runId", "")), "run ID")
    nodes = [{k: x[k] for k in ("rank", "host", "node")} for x in decl.get("containers", [])]
    require(sorted(nodes, key=lambda x: x["rank"]) == sorted(exp["nodes"], key=lambda x: x["rank"]), "foreign nodes")
    return {"version": 1, "invocationOwner": exp["invocationOwner"],
            "runId": decl["runId"], "declarationSha256": digest(raw)}


def offer(root, raw):
    require(len(raw) <= 1048576, "oversize declaration")
    check(root, raw)
    create(root, "offered.json", raw)


def acknowledge(root):
    raw = read(root, "offered.json")
    anchor = check(root, raw)
    create(root, "parent-anchor.json", encoded(anchor))
    # Acknowledgement appears only after the independent anchor is durable.
    create(root, "ack.json", encoded(anchor))
    return anchor


def verify_ack(root, raw):
    anchor = check(root, raw)
    require(read(root, "offered.json") == raw, "declaration changed after offer")
    require(document(root, "parent-anchor.json") == anchor
            and document(root, "ack.json") == anchor, "missing/stale parent acknowledgement")
    return anchor


def wait_ack(root, raw, seconds):
    require(type(seconds) is int and 1 <= seconds <= 120, "bounded acknowledgement wait required")
    deadline = time.monotonic() + seconds
    while True:
        try:
            return verify_ack(root, raw)
        except FileNotFoundError:
            require(time.monotonic() < deadline, "parent acknowledgement timed out; no resource staging allowed")
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    require(sys.flags.isolated and not sys.flags.optimize, "Python -I required")
    action, root = sys.argv[1:3]
    if action == "init":
        initialize(root, json.loads(Path(sys.argv[3]).read_bytes(), object_pairs_hook=pairs))
    elif action == "offer":
        offer(root, Path(sys.argv[3]).read_bytes())
    elif action == "ack":
        print(json.dumps(acknowledge(root), sort_keys=True))
    elif action == "wait":
        print(json.dumps(wait_ack(root, Path(sys.argv[3]).read_bytes(), int(sys.argv[4])), sort_keys=True))
    else:
        raise ValueError("unknown channel operation")
