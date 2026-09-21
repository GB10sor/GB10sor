#!/usr/bin/env python3
"""Source candidate: expand explicit two-node pins into finite link slots.

Local data only: never discover hosts, read model paths, configure networking,
start SSH, or launch a workload. The caller must independently verify host pins
and own network rollback before staging/using this plan. Not yet live-qualified.
"""
import copy
import hashlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("link_transport", HERE / "deuces-link-server-transport.py")
T = importlib.util.module_from_spec(spec)
spec.loader.exec_module(T)


def build(inputs, helper_bytes, owner):
    T.need(set(inputs) == {"version", "nodes", "settings"} and type(inputs["version"]) is int and inputs["version"] == 1,
           "explicit single-port plan input schema")
    T.need(T.hexseal(owner), "fresh caller ownership token")
    nodes, settings = inputs["nodes"], inputs["settings"]
    T.need(isinstance(nodes, list) and len(nodes) == 2, "exact left/right pair required")
    T.need(set(settings) == {"iperfSeconds", "iperfStreams", "rdmaSeconds", "leaseSeconds", "stopSeconds"}, "finite settings schema")
    for key, low, high in (("iperfSeconds", 1, 60), ("iperfStreams", 1, 16), ("rdmaSeconds", 1, 60),
                           ("leaseSeconds", 180, 900), ("stopSeconds", 1, 30)):
        T.need(type(settings[key]) is int and low <= settings[key] <= high, "bounded " + key)
    T.need(settings["leaseSeconds"] >= 2 * (settings["iperfSeconds"] + settings["rdmaSeconds"]) + 2 * settings["stopSeconds"] + 120,
           "link phase/cleanup margin exceeds declared lease")
    helper = {"__name__": "sealed_link_config_validation"}
    exec(compile(helper_bytes, "sealed-link-helper", "exec"), helper)
    seal = T.digest(helper_bytes)
    for node in nodes:
        T.need(set(node) == {"host", "stateParent", "identity", "address", "rdmaDevice", "gidIndex", "iperf", "perftest", "memlock"}, "node schema")
        T.need(set(node["identity"]) == {"hostname", "systemClosure", "bootId", "python", "tools"}, "host identity pins")
        T.need(T.path(node["stateParent"]) and node["stateParent"] != "/", "private state parent")
        address = ipaddress.IPv4Address(node["address"])
        T.need(address.is_private and not (address.is_loopback or address.is_link_local or address.is_unspecified or address.is_reserved or address.is_multicast), "private unicast link address")
        T.need(re.fullmatch(r"mlx5_[0-9]+", node["rdmaDevice"]) is not None and type(node["gidIndex"]) is int and 0 <= node["gidIndex"] <= 255, "explicit HCA/GID index")
        for key, binary in (("iperf", "iperf3"), ("perftest", "ib_write_bw")):
            pin = node[key]
            if key == "perftest" and pin is None: continue
            T.need(isinstance(pin, dict) and set(pin) == {"path", "sha256"} and T.hexseal(pin["sha256"]) and
                   isinstance(pin["path"], str) and re.fullmatch(r"/nix/store/[a-z0-9]+-[A-Za-z0-9._+-]+/bin/" + binary, pin["path"]), "immutable " + key)
    for key in ("host", "address"):
        T.need(nodes[0][key] != nodes[1][key], "duplicate pair " + key)
    T.need(nodes[0]["identity"]["hostname"] != nodes[1]["identity"]["hostname"], "duplicate node identity")
    T.need(nodes[0]["iperf"] == nodes[1]["iperf"] and nodes[0]["perftest"] == nodes[1]["perftest"], "both nodes must use exact same benchmark builds")
    slots = []

    def add(node, label, pin, args, memlock):
        token = hashlib.sha256((owner + ":" + label).encode()).hexdigest()[:32]
        state = node["stateParent"] + "/gb10sor-link-server." + token
        cfg = dict(copy.deepcopy(node["identity"]), version=2, owner=owner, unit=Path(state).name + ".service",
                   argv=[pin["path"], *args], binarySha256=pin["sha256"], workerSha256=seal,
                   leaseSeconds=settings["leaseSeconds"], stopSeconds=settings["stopSeconds"], memlock=copy.deepcopy(memlock))
        helper["validate"](cfg, Path(state))
        slots.append(dict(host=node["host"], label=label, state=state, config=cfg, configSha256=T.digest(T.encoded(cfg))))

    for index, direction in enumerate(("left-to-right", "right-to-left")):
        client, server = nodes[index], nodes[1-index]
        port = str(5211 + index); label = "rail-a-" + direction
        add(server, label, server["iperf"], ["-s", "-1", "-B", server["address"], "-p", port], {"mode": "inherit"})
        add(client, label + "-client", client["iperf"], ["-c", server["address"], "-B", client["address"], "-p", port,
            "-t", str(settings["iperfSeconds"]), "-P", str(settings["iperfStreams"]), "-J"], {"mode": "inherit"})
        if server["perftest"] is not None:
            port = str(5311 + index); label = "rdma-a-" + direction
            for node, suffix, peer in ((server, "", []), (client, "-client", [server["address"]])):
                add(node, label + suffix, node["perftest"], ["-d", node["rdmaDevice"], "-F", "-D", str(settings["rdmaSeconds"]),
                    "-x", str(node["gidIndex"]), "-s", "1048576", "-p", port, *peer], node["memlock"])
    return T.validate(dict(version=1, owner=owner, helperSha256=seal, slots=slots))


def main():
    T.need(len(sys.argv) == 5, "INPUT INPUT_SHA HELPER NEW_OUTPUT_DIRECTORY")
    source, seal, worker, destination = sys.argv[1:]
    data = T.private_read(source)
    T.need(T.hexseal(seal) and T.digest(data) == seal, "input changed")
    helper = T.private_read(worker, public=True)
    plan = build(json.loads(data), helper, os.urandom(32).hex())
    root = Path(destination)
    T.need(root.is_absolute() and str(root.parent.resolve(strict=True)) == str(root.parent), "canonical output parent required")
    root.mkdir(mode=0o700)  # One claim only; never replace a prior plan.
    T.publish(root, "input.json", json.loads(data))
    T.publish(root, "plan.json", plan)
    receipt = dict(result="pass", scope="local-plan-only-not-host-verification", inputSha256=seal,
                   helperSha256=T.digest(helper), planSha256=T.digest(T.encoded(plan)), slots=len(plan["slots"]))
    T.publish(root, "plan-receipt.json", receipt)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == "__main__":
    main()
