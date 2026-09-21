#!/usr/bin/env python3
"""Pure local preparation/archive adapter for finite Deuces qualification.

No SSH, container or service calls. The shell parent owns execution. This is a
source candidate, not evidence of a deployed two-rank lifecycle. A resource
aggregate deliberately says nothing about firewall or interface restoration.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import uuid


def require(value, why):
    if not value:
        raise ValueError(why)


def raw_json(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def hex64(value):
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None


def atomic(path, value, fresh=False):
    require(not path.is_symlink() and (not fresh or not path.exists()), "existing/unsafe destination")
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temp.open("xb") as output:
        os.chmod(temp, 0o600)
        output.write(raw_json(value))
        output.flush()
        os.fsync(output.fileno())
    os.replace(temp, path)


def budget(settings):
    """Whole-script caps are enforced by the caller; socket timeouts are not caps.

    Count concurrency serially for reserve purposes, even though the workload
    itself stays concurrent. Preserve every existing assertion/request budget.
    The 900s preparation reserve includes both guards/create/start and the 2s
    start-order delay. Cleanup reserve includes helper oneshot + stop grace.
    """
    keys = {"startup", "request", "serve", "qualify", "lease", "hermes", "streaming",
            "structured", "image", "audio", "stressTokens", "concurrency"}
    require(set(settings) == keys, "budget schema")
    for key in ("startup", "request", "serve", "lease", "stressTokens", "concurrency"):
        require(type(settings[key]) is int and settings[key] >= 0, "invalid budget integer")
    for key in ("qualify", "hermes", "streaming", "structured", "image", "audio"):
        require(type(settings[key]) is bool, "invalid budget boolean")
    require(1 <= settings["startup"] <= 7200 and 1 <= settings["request"] <= 1800, "unsafe test timeout")
    require(not settings["qualify"] or settings["serve"] > 0, "owned mode refuses unlimited serving")
    require(settings["qualify"] or settings["serve"] == 0, "unused serving budget")
    require(0 <= settings["concurrency"] <= 32 and 0 <= settings["stressTokens"] <= 65536, "stress bounds")
    require((settings["concurrency"] == 0) == (settings["stressTokens"] == 0), "partial stress contract")
    request = settings["request"]
    caps = {"ready": request + 30, "runtime": 120, "completion": 2 * request + 30,
            "hermes": 4 * request + 30, "streaming": request + 30,
            "structured": request + 30, "image": request + 30, "audio": request + 30,
            "stress": (4 + settings["concurrency"]) * request + 30}
    test = caps["completion"] + 2 * caps["runtime"]
    for key in ("hermes", "streaming", "structured", "image", "audio"):
        if settings[key]:
            test += caps[key]
    if settings["stressTokens"]:
        test += caps["stress"]
    # Startup can overshoot by one complete readiness request and one poll.
    # Both ranks: inspect/log (150+30+60+10), stop (360+30),
    # disarm (180+30), archive (180+10), with bookkeeping reserve. Distinct
    # from an individual guard's 300+30s execution bound.
    cleanup_reserve = 2400
    required = 900 + settings["startup"] + caps["ready"] + 5 + test + settings["serve"] + 10 + cleanup_reserve
    require(180 <= settings["lease"] <= 43200 and settings["lease"] >= required,
            f"finite lease too short; require at least {required}s (maximum 43200s)")
    return {"requiredSeconds": required, "leaseSeconds": settings["lease"], "execCaps": caps,
            "preparationSeconds": 900, "cleanupReserveSeconds": cleanup_reserve, "startDelaySeconds": 2}


def load_helper(path):
    spec = importlib.util.spec_from_file_location("owned_container_contract", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def transform_command(argv, tools, image):
    require(isinstance(argv, list) and argv[:3] == ["podman", "run", "-d"], "legacy argv shape changed")
    result = [tools["podman"], "create", *argv[3:]]
    require(result.count(image) == 1, "ambiguous image boundary")
    position = result.index(image)
    options = result[2:position]
    require(options.count("--entrypoint") == 1, "missing/duplicate entrypoint")
    mounts = []
    for index, arg in enumerate(options):
        if arg == "-v":
            require(index + 1 < len(options), "missing mount value")
            parts = options[index + 1].split(":")
            require(len(parts) == 3 and parts[2] == "ro", "unexpected writable/ambiguous bind")
            mounts.append({"source": parts[0], "destination": parts[1], "readonly": True})
    return result, mounts, options[options.index("--entrypoint") + 1], result[position + 1:]


def plan(spec, helper_path):
    require(spec["engine"] in ("vllm", "sglang") and hex64(spec["invocationOwner"]), "engine/parent owner")
    require(re.fullmatch(r"gb10sor-(vllm|sglang)-[A-Za-z0-9-]+", spec["runId"]), "run ID")
    require(set(spec["sourceSha256"]) == {"engine", "containerHelper", "hashHelper", "adapter"}
            and all(hex64(x) for x in spec["sourceSha256"].values()), "source manifest")
    require(sha(Path(helper_path).read_bytes()) == spec["sourceSha256"]["containerHelper"], "helper changed")
    require(len(spec["nodes"]) == 2 and {n["rank"] for n in spec["nodes"]} == {0, 1}, "two ranks required")
    require(len({n["host"] for n in spec["nodes"]}) == 2 and len({n["node"] for n in spec["nodes"]}) == 2, "duplicate hosts")
    bounds, helper, configs, containers = budget(spec["settings"]), load_helper(helper_path), [], []
    for node in sorted(spec["nodes"], key=lambda n: n["rank"]):
        require(re.fullmatch(r"[A-Za-z0-9_.@:-]+", node["host"]), "unsafe transport host")
        command, mounts, entrypoint, args = transform_command(node["argv"], node["tools"], node["imageRef"])
        cfg = {"version": 1, "owner": spec["invocationOwner"], "rank": node["rank"],
               "name": spec["runId"] + "-rank" + str(node["rank"]), "hostname": node["node"],
               "systemClosure": node["systemClosure"], "imageRef": node["imageRef"],
               "imageId": node["imageId"], "imageLayersSha256": node["imageLayersSha256"],
               "createArgv": command, "mounts": mounts, "entrypoint": entrypoint, "args": args,
               "leaseSeconds": bounds["leaseSeconds"], "cleanupSeconds": 300, "stopSeconds": 30,
               "python": node["python"], "tools": node["tools"],
               "sources": {"worker.py": spec["sourceSha256"]["containerHelper"]}}
        root = Path(node["stateRoot"])
        require(root.is_absolute() and ".." not in root.parts, "unsafe state root")
        helper.validate_config(cfg, root)
        configs.append(cfg)
        containers.append({key: node[key] for key in ("rank", "host", "node", "stateRoot")}
                          | {"configSha256": sha(raw_json(cfg))})
    require(configs[0]["imageId"] == configs[1]["imageId"] and configs[0]["imageLayersSha256"] == configs[1]["imageLayersSha256"], "rank image mismatch")
    hashes = spec["hashes"]
    require(len(hashes) >= 2 and len({x["slot"] for x in hashes}) == len(hashes), "hash slots")
    for item in hashes:
        require(set(item) == {"slot", "rank", "host", "stateRoot", "unit", "token", "helperSha256", "expectedTreeSha256"}, "hash declaration schema")
        require(item["rank"] in (0, 1) and item["host"] == containers[item["rank"]]["host"], "hash rank/host")
        require(item["slot"] in ("target-rank" + str(item["rank"]), "auxiliary-rank" + str(item["rank"]), "draft-rank" + str(item["rank"])), "hash slot kind")
        require(all(hex64(item[k]) for k in ("token", "helperSha256", "expectedTreeSha256")), "hash seals")
        require(item["helperSha256"] == spec["sourceSha256"]["hashHelper"], "hash helper source")
        require(re.fullmatch(r"gb10sor-vllm-[A-Za-z0-9-]+-weights-rank[01]", item["unit"])
                and item["stateRoot"] == "/tmp/" + item["unit"], "hash unit/root")
    require({x["slot"] for x in hashes} >= {"target-rank0", "target-rank1"}, "target slots missing")
    declaration = {"schemaVersion": 1, "kind": "gb10sor.deuces.resource-declaration",
                   **{key: spec[key] for key in ("invocationOwner", "runId", "engine", "sourceSha256")},
                   "containers": containers, "hashes": hashes}
    return declaration, configs, bounds


def archive_file(root, relative):
    path = root
    require(not Path(relative).is_absolute() and all(x not in ("", ".", "..") for x in relative.split("/")), "unsafe archive path")
    for part in relative.split("/"):
        path /= part
        require(not path.is_symlink(), "symlink archive")
    require(path.is_file() and path.stat().st_size <= 8 * 1024 * 1024, "missing/oversize archive")
    return path.read_bytes()


def reference(root, role, relative):
    return {"role": role, "path": relative, "sha256": sha(archive_file(root, relative))}


def properties(raw):
    result = {}
    for line in raw.decode().splitlines():
        key, value = line.split("=", 1)
        require(key not in result, "duplicate property")
        result[key] = value
    return result


def hash_leaf(root, expected, owner, cleanup_status, archive, output):
    require(type(cleanup_status) is int and cleanup_status == 0, "hash cleanup command failed")
    files = {name: reference(root, name, archive + "/" + name)
             for name in ("owner", "hash.sh", "helper.sha256", "cancelled")}
    files["cleanup-output"] = reference(root, "cleanup-output", output)
    require(archive_file(root, archive + "/owner").decode().strip() == expected["token"], "hash owner mismatch")
    require(files["hash.sh"]["sha256"] == expected["helperSha256"], "hash helper mismatch")
    require(archive_file(root, archive + "/helper.sha256").decode().split() == [expected["helperSha256"], "hash.sh"], "hash helper manifest")
    reply = archive_file(root, output).decode().strip()
    invocation = group = None
    if reply == "never-started":
        outcome = "canceled"
        require(not any((root / archive / name).exists() or (root / archive / name).is_symlink()
                        for name in ("start-attempted", "identity.txt", "before-stop.txt", "stop.receipt")), "canceled hash has attempted start")
    else:
        outcome = "stopped"
        require(reply in ("owned-unit-stopped-empty", "owned-unit-already-stopped-empty"), "unknown hash stop response")
        for name in ("stop.receipt", "stop-proof.sha256", "before-stop.txt", "after-stop.txt", "expected-argv", "expected-argv.sha256"):
            files[name] = reference(root, name, archive + "/" + name)
        lines = archive_file(root, archive + "/stop.receipt").decode().splitlines()
        require(len(lines) == 5 and lines[:2] == [expected["token"], expected["unit"]] and lines[4] == "owned-unit-stopped-empty", "hash stop receipt")
        invocation, group = lines[2:4]
        require(re.fullmatch(r"[0-9a-f]{32}", invocation) and group.startswith("/user.slice/") and group.endswith("/" + expected["unit"] + ".service") and ".." not in group, "hash invocation/cgroup")
        before = properties(archive_file(root, archive + "/before-stop.txt"))
        after = properties(archive_file(root, archive + "/after-stop.txt"))
        require(before.get("InvocationID") == invocation and before.get("Description") == "GB10 owned weight hash " + expected["token"]
                and before.get("KillMode") == "control-group" and before.get("ControlGroup") in ("", group), "hash pre-stop identity")
        require(after.get("LoadState") in ("loaded", "not-found") and after.get("MainPID") == "0"
                and (after.get("ActiveState"), after.get("SubState")) in (("inactive", "dead"), ("failed", "failed"))
                and after.get("InvocationID") in ("", invocation) and after.get("ControlGroup") in ("", group), "hash post-stop identity/live state")
        require(archive_file(root, archive + "/expected-argv.sha256").decode().split() == [files["expected-argv"]["sha256"], "expected-argv"], "hash argv manifest")
        proof = {}
        for line in archive_file(root, archive + "/stop-proof.sha256").decode().splitlines():
            seal, name = line.split("  ", 1)
            require(name in files and name not in proof and files[name]["sha256"] == seal, "hash stop proof changed")
            proof[name] = seal
        require(set(proof) == {"before-stop.txt", "after-stop.txt", "stop.receipt", "expected-argv", "expected-argv.sha256"}, "hash stop proof incomplete")
    return {"schemaVersion": 1, "kind": "gb10sor.deuces.hash-resource", "invocationOwner": owner,
            **expected, "result": outcome, "cleanupStatus": cleanup_status,
            "unitInvocationId": invocation, "cgroup": group, "archivePath": archive,
            "files": list(files.values())}


def aggregate(root, statuses):
    """Archive-derived positive child evidence, never a network restoration claim."""
    declaration_raw = archive_file(root, "owned/declaration.json")
    declaration = json.loads(declaration_raw)
    require(set(statuses) == {"containers", "hashes"}, "cleanup status schema")
    result = {**{k: declaration[k] for k in ("schemaVersion", "invocationOwner", "runId", "engine", "sourceSha256")},
              "kind": "gb10sor.deuces.child-resources", "result": "failed",
              "declaration": {"path": "owned/declaration.json", "sha256": sha(declaration_raw)},
              "containers": [], "hashes": [], "errors": []}
    for expected in declaration["containers"]:
        try:
            records = [x for x in statuses["containers"] if x.get("rank") == expected["rank"]]
            require(len(records) == 1, "missing/duplicate cleanup status")
            status = records[0]
            require(set(status) == {"rank", "archivePath", "cleanupStatus", "disarmStatus", "archiveStatus", "captureStatus"}, "container status schema")
            require(all(type(status[k]) is int and status[k] == 0 for k in ("cleanupStatus", "disarmStatus", "archiveStatus")), "container cleanup/archive failed")
            require(type(status["captureStatus"]) is int and status["captureStatus"] in (0, 1), "capture diagnostic status")
            roles = ("config", "prepared", "cleanup", "disarmed", "cid", "removed")
            refs = [reference(root, role, status["archivePath"] + "/" + role + ".json") for role in roles]
            values = {ref["role"]: json.loads(archive_file(root, ref["path"])) for ref in refs}
            require(refs[0]["sha256"] == expected["configSha256"], "config seal mismatch")
            cfg = values["config"]
            require(cfg["hostname"] == expected["node"] and cfg["rank"] == expected["rank"] and cfg["owner"] == declaration["invocationOwner"], "config identity")
            require(cfg["sources"] == {"worker.py": declaration["sourceSha256"]["containerHelper"]}, "container source changed")
            cid = values["cid"].get("cid")
            require(hex64(cid) and values["removed"].get("cid") == cid, "positive CID/removal required")
            for role in roles[1:]:
                value = values[role]
                require(value.get("owner") == declaration["invocationOwner"] and value.get("configSha256") == expected["configSha256"], "foreign container receipt")
                if role != "cid":
                    require(value.get("result") == "pass", "failed container receipt")
            require(values["cleanup"].get("errors") == [], "container cleanup errors")
            result["containers"].append({**expected, "cid": cid, "receipts": refs, "captureStatus": status["captureStatus"]})
        except (ValueError, OSError, KeyError, TypeError) as error:
            result["errors"].append("container rank" + str(expected["rank"]) + ": " + str(error))
    for expected in declaration["hashes"]:
        try:
            records = [x for x in statuses["hashes"] if x.get("slot") == expected["slot"]]
            require(len(records) == 1, "missing/duplicate hash cleanup status")
            status = records[0]
            require(set(status) == {"slot", "cleanupStatus", "archiveStatus", "archivePath", "outputPath"}, "hash status schema")
            require(type(status["archiveStatus"]) is int and status["archiveStatus"] == 0, "hash archive failed")
            leaf = hash_leaf(root, expected, declaration["invocationOwner"], status["cleanupStatus"], status["archivePath"], status["outputPath"])
            path = "owned/hash-" + expected["slot"] + ".json"
            atomic(root / path, leaf)
            result["hashes"].append({k: expected[k] for k in ("slot", "host", "stateRoot")}
                                    | {"receipts": [reference(root, leaf["result"], path)]})
        except (ValueError, OSError, KeyError, TypeError) as error:
            result["errors"].append("hash " + expected["slot"] + ": " + str(error))
    if not result["errors"]:
        result["result"] = "pass"
    atomic(root / "owned/child-resources.json", result)
    return result


def main():
    require(sys.flags.isolated and not sys.flags.optimize, "Python -I required")
    action = sys.argv[1]
    if action == "budget":
        print(json.dumps(budget(json.loads(sys.argv[2])), sort_keys=True))
    elif action == "plan":
        spec_path, helper_path, output_path = map(Path, sys.argv[2:])
        declaration, configs, bounds = plan(json.loads(spec_path.read_text()), helper_path)
        output_path.mkdir(mode=0o700)
        for cfg in configs:
            atomic(output_path / ("rank" + str(cfg["rank"]) + "-config.json"), cfg, fresh=True)
        atomic(output_path / "budget.json", bounds, fresh=True)
        atomic(output_path / "declaration.json", declaration, fresh=True)
        print(sha(raw_json(declaration)))
    elif action == "aggregate":
        root, status_path = map(Path, sys.argv[2:])
        result = aggregate(root, json.loads(status_path.read_text()))
        print(json.dumps(result, sort_keys=True))
        if result["result"] != "pass":
            sys.exit(1)
    else:
        raise ValueError("unknown pure adapter action")


if __name__ == "__main__":
    main()
