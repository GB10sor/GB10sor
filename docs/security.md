# Operational security

GB10SOR follows four practical principles for its current Solo recipes.

## Simplicity

Only the selected flake output, profile, and required launcher are used. Entering a development shell does not start a workload automatically.

## Integrity

Nix inputs and external source revisions are pinned. Runtime images are selected by immutable digest, and the repository checksum manifest detects changed or missing release files.

## Least privilege

Inference binds to loopback by default. Checkpoints are mounted read-only where supported, secrets are not inherited by model containers, and recipes do not weaken Docker socket permissions. Docker socket access remains root-equivalent.

## Defense in depth

Preflight, acceptance, identity, and cleanup checks fail closed. A changed checkpoint, image, source revision, flag set, driver, or host is treated as a new candidate. Keep the factory operating system recoverable and follow NVIDIA firmware and operating-system guidance.

## Trust boundaries

- Nix store paths are readable by local users. Never put secrets in a flake, derivation, command argument, tracked environment file, or evidence record.
- Model loaders and containers execute third-party code. Use the pinned revisions and digests, read-only checkpoint mounts, no inherited secrets, and the smallest practical network boundary.
- Use authenticated SSH forwarding for remote access. Do not expose an unauthenticated model API to a LAN or the Internet.
- Never add `sudo`, disable a check, change a digest, relax a memory or context bound, or open a firewall port merely to turn a failure green.

To report a vulnerability, follow the [security policy](../SECURITY.md).
