# DGX Spark quickstart

Use this guide with DGX OS or NixOS. The GB10SOR AArch64 USB image was verified on DGX Spark, including internal NVMe detection and installation alongside DGX OS. For deeper OS, kernel, CUDA, cache, and playbook compatibility details, see [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark).

## Before you start

- Back up anything you cannot replace and keep stable power and Internet access.
- Update firmware while DGX OS still boots. Factory firmware may not boot NixOS.
- Plan for at least 300 GiB of free local storage; some checkpoints need considerably more.
- Stop other GPU jobs and containers before qualification.
- Install rootless Podman or Docker with NVIDIA CDI support.
- Stage model weights yourself. These repositories never download or redistribute them.

## 1. Choose an operating-system path

### Keep DGX OS

Install Nix in multi-user mode using the [official Nix instructions](https://nixos.org/download/), then enable flakes in `/etc/nix/nix.conf`:

```text
experimental-features = nix-command flakes
```

Open a new terminal and confirm the daemon is available:

```bash
nix --version
nix store ping --store daemon
```

### Install NixOS from USB

Writing the image erases the selected USB drive. Installing NixOS afterward can erase the DGX Spark's internal drive, so confirm every device name before continuing.

First update firmware from DGX OS:

```bash
fwupdmgr get-updates
sudo fwupdmgr update
```

Use the GB10SOR DGX Spark AArch64 installer image and its matching `SHA256SUMS` file from the same release. The image is built on AArch64 and includes the NVMe support needed by the installer. Do not continue if either file is missing or the checksum fails:

```bash
sha256sum --check SHA256SUMS
```

Insert the USB drive and identify its **whole-disk** device. Compare the size and model carefully; do not use a partition such as `/dev/sdX1`:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

Unmount any mounted partitions on that USB drive. Replace `/dev/sdX` below with its whole-disk device, check it once more, then write the image:

```bash
iso=/path/to/gb10sor-dgx-spark-aarch64.iso
test -f "$iso"
test -b /dev/sdX
sudo dd if="$iso" of=/dev/sdX bs=1M status=progress
sync
```

Disable Secure Boot in the DGX Spark firmware settings and boot from the USB drive. Before installing, confirm that the installer sees the internal NVMe and the existing DGX OS installation. Choose **Install alongside** only when the installer offers it. Keep the DGX OS, recovery, and EFI partitions, and do not choose **Erase disk**, **Replace a partition**, or format those partitions. Stop if the NVMe is missing, the alongside option is absent, the drive is encrypted, or an erase warning is unclear.

After installation, remove the USB drive and confirm that both NixOS and DGX OS boot. Use [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) for broader compatibility notes and its DGX Spark configuration template.

## 2. Check the host

Run these as your normal user:

```bash
set -euo pipefail
test "$(uname -m)" = aarch64
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total \
  --format=csv,noheader
df -h /
systemctl is-system-running
timedatectl show -p NTPSynchronized --value
if command -v podman >/dev/null; then podman info >/dev/null; else docker info >/dev/null; fi
```

Continue only when the GPU is `NVIDIA GB10` with compute capability `12.1`, systemd is healthy, time is synchronized, storage is sufficient, and the container engine works without a root shell.

## 3. Get and verify GB10SOR

```bash
git clone https://github.com/GB10sor/GB10sor.git
cd GB10sor
nix run path:.#verify
nix flake show --no-write-lock-file
```

Do not continue if verification fails.

## 4. Pick a profile and stage its checkpoint

```bash
nix develop path:.#framework --command jq -r '.profiles | keys[]' model-profiles.json
nix develop path:.#model-PROFILE --command ./scripts/launch-model.sh show
```

Replace `PROFILE` with one of the listed names. Put the complete checkpoint at the exact revision under `GB10_MODEL_ROOT`, which defaults to `$HOME/.local/share/gb10sor/models`. Multi-Spark profiles need the same validated weight tree on the required nodes and the private, untracked lane settings in [cluster configuration](docs/configuration.md).

## 5. Qualify and serve

```bash
nix develop path:.#model-PROFILE --command \
  ./scripts/launch-model.sh qualify-and-serve
```

The launcher checks the pinned checkpoint, runtime image, hardware, topology, and acceptance boundary before serving. The API stays on loopback. Use SSH or another authenticated private access layer for remote clients.

Stop the deployment from another terminal:

```bash
nix develop path:.#model-PROFILE --command ./scripts/launch-model.sh stop
```

If a check fails, keep the failure closed. Do not remove checks, change digests, add broad privileges, or expose a port to make the run pass. See [operational security](docs/security.md) and [Graham's compatibility guide](https://github.com/graham33/nixos-dgx-spark) before changing the host.
