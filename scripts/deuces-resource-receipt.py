"""Read-only child-resource receipt gate; NOT a live network/idle-state check.

The parent must supply its fresh invocation token and the declaration digest it
recorded before remote writes. A child-generated digest is not a trust anchor.
This draft consumer is not wired into the portable outer launcher yet.
"""
import hashlib
import json
from pathlib import Path
import re
import sys


def require(value, reason):
    if not value:
        raise ValueError(reason)


def hex64(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


class Evidence:
    def __init__(self, root):
        self.root = Path(root)
        require(self.root.is_dir() and not self.root.is_symlink(), "invalid evidence root")

    def path(self, name):
        require(isinstance(name, str) and name and not Path(name).is_absolute(), "relative evidence path required")
        require(all(p not in ("", ".", "..") for p in name.split("/")), "unsafe evidence path")
        current = self.root
        for part in name.split("/"):
            current = current / part
            require(not current.is_symlink(), "symlink evidence rejected")
        return current

    def read(self, name, seal):
        require(hex64(seal), "invalid evidence digest")
        path = self.path(name)
        require(path.is_file() and path.stat().st_size <= 8 * 1024 * 1024, "missing/oversize evidence")
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == seal, "changed evidence: " + name)
        return data

    def document(self, name, seal):
        result = json.loads(self.read(name, seal), object_pairs_hook=unique_object)
        require(isinstance(result, dict), "object receipt required")
        return result

    def receipts(self, items):
        require(isinstance(items, list) and items, "missing receipt list")
        result = {}
        for item in items:
            require(set(item) == {"role", "path", "sha256"}, "receipt reference schema")
            require(isinstance(item["role"], str) and item["role"] not in result, "duplicate receipt role")
            self.read(item["path"], item["sha256"])
            result[item["role"]] = item
        return result


def same(actual, expected, fields):
    require(all(actual.get(key) == expected.get(key) for key in fields), "resource identity mismatch")


def properties(raw):
    return unique_object(line.split("=", 1) for line in raw.decode().splitlines())


def validate(root, invocation_owner, declaration_sha):
    require(hex64(invocation_owner) and hex64(declaration_sha), "parent token/digest required")
    evidence = Evidence(root)
    declaration = evidence.document("owned/declaration.json", declaration_sha)
    require(declaration.get("schemaVersion") == 1 and declaration.get("kind") == "gb10sor.deuces.resource-declaration", "declaration version")
    require(declaration.get("invocationOwner") == invocation_owner, "foreign declaration")
    require(declaration.get("engine") in ("vllm", "sglang"), "unknown engine")
    require(isinstance(declaration.get("runId"), str) and re.fullmatch(r"gb10sor-[A-Za-z0-9-]+", declaration["runId"]), "run identity missing")
    sources = declaration.get("sourceSha256", {})
    require(set(sources) == {"engine", "containerHelper", "hashHelper", "adapter"} and all(hex64(v) for v in sources.values()), "source digest contract")
    # The aggregate itself is written atomically by the child. Its leaf digests
    # are checked against the parent's pre-write declaration, not self-trusted.
    aggregate_path = evidence.path("owned/child-resources.json")
    require(aggregate_path.is_file() and aggregate_path.stat().st_size <= 1024 * 1024, "missing/oversize aggregate")
    aggregate = json.loads(aggregate_path.read_bytes(), object_pairs_hook=unique_object)
    same(aggregate, declaration, ("schemaVersion", "invocationOwner", "runId", "engine", "sourceSha256"))
    require(aggregate.get("kind") == "gb10sor.deuces.child-resources" and aggregate.get("result") == "pass" and aggregate.get("errors") == [], "child resources not positive")
    require(aggregate.get("declaration") == {"path": "owned/declaration.json", "sha256": declaration_sha}, "stale declaration reference")
    expected_containers = declaration.get("containers", [])
    containers = aggregate.get("containers", [])
    require(len(expected_containers) == len(containers) == 2, "exactly two container slots required")
    require({x.get("rank") for x in expected_containers} == {0, 1} and {x.get("rank") for x in containers} == {0, 1}, "container rank coverage")
    require(len({x.get("node") for x in expected_containers}) == 2, "distinct nodes required")
    for expected in expected_containers:
        require(all(isinstance(expected.get(k), str) and expected[k] for k in ("host", "node", "stateRoot")) and hex64(expected.get("configSha256")), "container declaration incomplete")
        item = next(x for x in containers if x["rank"] == expected["rank"])
        same(item, expected, ("rank", "host", "node", "configSha256", "stateRoot"))
        require(hex64(item.get("cid")), "registered CID required for positive aggregate")
        refs = evidence.receipts(item.get("receipts"))
        require({"config", "prepared", "cleanup", "disarmed", "cid", "removed"} <= set(refs), "container proof incomplete")
        cfg = evidence.document(refs["config"]["path"], item["configSha256"])
        require(refs["config"]["sha256"] == item["configSha256"], "config reference changed")
        same(cfg, {"owner": invocation_owner, "rank": item["rank"], "hostname": item["node"]}, ("owner", "rank", "hostname"))
        require(cfg.get("sources") == {"worker.py": sources["containerHelper"]}, "container helper changed")
        for role in ("prepared", "cleanup", "disarmed", "cid", "removed"):
            receipt = evidence.document(refs[role]["path"], refs[role]["sha256"])
            same(receipt, {"owner": invocation_owner, "configSha256": item["configSha256"]}, ("owner", "configSha256"))
            if role in ("cid", "removed"):
                require(receipt.get("cid") == item["cid"], "CID receipt mismatch")
            if role != "cid":
                require(receipt.get("result") == "pass", "container leaf failed")
            if role == "cleanup":
                require(receipt.get("errors") == [], "container cleanup errors")
    expected_hashes = declaration.get("hashes", [])
    hashes = aggregate.get("hashes", [])
    require(len(expected_hashes) >= 2 and len(expected_hashes) == len(hashes), "hash slot coverage")
    require(len({x.get("slot") for x in expected_hashes}) == len(expected_hashes), "duplicate declared hash slot")
    require({"target-rank0", "target-rank1"} <= {x.get("slot") for x in expected_hashes}, "target hash coverage missing")
    require(len({x.get("slot") for x in hashes}) == len(hashes), "duplicate hash slot")
    require({x.get("slot") for x in hashes} == {x.get("slot") for x in expected_hashes}, "hash slot mismatch")
    for expected in expected_hashes:
        require(type(expected.get("rank")) is int and expected["rank"] in (0, 1), "hash rank invalid")
        require(re.fullmatch(r"(target|auxiliary|draft)-rank" + str(expected["rank"]), expected.get("slot", "")), "hash slot/rank mismatch")
        require(all(hex64(expected.get(k)) for k in ("token", "helperSha256", "expectedTreeSha256")), "hash declaration digests missing")
        require(isinstance(expected.get("unit"), str) and re.fullmatch(r"gb10sor-vllm-[A-Za-z0-9-]+-weights-rank[01]", expected["unit"]), "hash unit declaration invalid")
        require(expected.get("host") == next(x["host"] for x in expected_containers if x["rank"] == expected["rank"]), "hash node/rank mismatch")
        item = next(x for x in hashes if x["slot"] == expected["slot"])
        same(item, expected, ("slot", "host", "stateRoot"))
        refs = evidence.receipts(item.get("receipts"))
        require(len(refs) == 1 and set(refs) <= {"stopped", "canceled"}, "hash cleanup outcome missing")
        role, ref = next(iter(refs.items()))
        leaf = evidence.document(ref["path"], ref["sha256"])
        require(leaf.get("schemaVersion") == 1 and leaf.get("kind") == "gb10sor.deuces.hash-resource", "hash leaf schema")
        same(leaf, expected, ("slot", "rank", "host", "stateRoot", "unit", "token", "helperSha256", "expectedTreeSha256"))
        require(leaf.get("invocationOwner") == invocation_owner and leaf.get("result") == role and leaf.get("cleanupStatus") == 0, "hash cleanup not positive")
        require(leaf["helperSha256"] == sources["hashHelper"], "hash helper mismatch")
        files = evidence.receipts(leaf.get("files"))
        require({"owner", "hash.sh", "helper.sha256", "cancelled", "cleanup-output"} <= set(files), "hash file proof incomplete")
        raw = {key: evidence.read(value["path"], value["sha256"]) for key, value in files.items()}
        for key, ref_file in files.items():
            if key != "cleanup-output":
                require(ref_file["path"] == leaf["archivePath"] + "/" + key, "hash file escaped its declared archive")
        require(raw["owner"].decode().strip() == leaf["token"] and files["hash.sh"]["sha256"] == sources["hashHelper"], "hash owner/source changed")
        require(raw["helper.sha256"].decode().split() == [sources["hashHelper"], "hash.sh"], "hash source manifest mismatch")
        archive = evidence.path(leaf["archivePath"])
        require(archive.is_dir(), "hash archive missing")
        if role == "canceled":
            require(leaf.get("unitInvocationId") is None and leaf.get("cgroup") is None, "canceled hash has invocation")
            require(raw["cleanup-output"].decode().strip() == "never-started", "cancellation reply missing")
            require(not any((archive / name).exists() or (archive / name).is_symlink() for name in ("start-attempted", "identity.txt", "before-stop.txt", "stop.receipt")), "canceled hash has start evidence")
        else:
            require({"stop.receipt", "stop-proof.sha256", "before-stop.txt", "after-stop.txt", "expected-argv", "expected-argv.sha256"} <= set(files), "stop proof incomplete")
            require(re.fullmatch(r"[0-9a-f]{32}", leaf.get("unitInvocationId", "")), "hash invocation missing")
            group = leaf.get("cgroup", "")
            require(group.startswith("/user.slice/") and group.endswith("/" + leaf["unit"] + ".service") and ".." not in group, "hash cgroup mismatch")
            require(raw["stop.receipt"].decode().splitlines() == [leaf["token"], leaf["unit"], leaf["unitInvocationId"], group, "owned-unit-stopped-empty"], "stop receipt identity")
            require(raw["cleanup-output"].decode().strip() in ("owned-unit-stopped-empty", "owned-unit-already-stopped-empty"), "stop reply missing")
            before, after = properties(raw["before-stop.txt"]), properties(raw["after-stop.txt"])
            same(before, {"InvocationID": leaf["unitInvocationId"], "Description": "GB10 owned weight hash " + leaf["token"], "KillMode": "control-group"}, ("InvocationID", "Description", "KillMode"))
            require(before.get("ControlGroup") in ("", group), "hash pre-stop cgroup changed")
            require(after.get("LoadState") in ("loaded", "not-found") and after.get("MainPID") == "0", "hash post-stop state unknown/live")
            require((after.get("ActiveState"), after.get("SubState")) in (("inactive", "dead"), ("failed", "failed")), "hash post-stop state not stopped")
            require(after.get("InvocationID") in ("", leaf["unitInvocationId"]) and after.get("ControlGroup") in ("", group), "hash post-stop identity changed")
            require(raw["expected-argv.sha256"].decode().split() == [files["expected-argv"]["sha256"], "expected-argv"], "hash argv manifest changed")
            proof = {}
            for line in raw["stop-proof.sha256"].decode().splitlines():
                seal, name = line.split("  ", 1)
                require(name in files and name not in proof and files[name]["sha256"] == seal, "stop manifest changed")
                proof[name] = seal
            require(set(proof) == {"before-stop.txt", "after-stop.txt", "stop.receipt", "expected-argv", "expected-argv.sha256"}, "stop manifest incomplete")
    return {"result": "pass", "invocationOwner": invocation_owner, "containers": 2, "hashes": len(hashes), "scope": "archived-child-resources-only"}


if __name__ == "__main__":
    require(len(sys.argv) == 4, "usage: evidence-root parent-owner pre-write-declaration-sha256")
    print(json.dumps(validate(*sys.argv[1:]), sort_keys=True))
