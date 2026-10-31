# fluffy-couscous

[![CodeFactor](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous/badge)](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous)

Automated Gentoo stage3 builder, binary package host, UEFI Secure Boot live ISO generator, and target system installer.

## Overview

This project provides a standalone toolchain that builds, updates, and installs custom Gentoo systems without using Gentoo Catalyst:

- **Bootstrap (`bin/bootstrap.sh`)**: Builds an initial base `stage3` archive and binary package repository from an official Gentoo seed stage.
- **System Updates (`bin/update.sh`)**: Updates `@system` packages, rebuilds preserved libraries, and refreshes the base `stage3` archive on S3.
- **Package Builds (`bin/build.sh`)**: Compiles target packages against the profile's `stage3` and syncs new binary packages to S3.
- **Live Installer ISO (`bin/build-install.sh`)**: Builds a bootable UEFI Secure Boot live installer ISO bundled with the installer and binary repository configs.
- **Google Cloud Image (`bin/build-gce.sh`)**: Builds a Google Compute Engine
  (GCE) custom raw disk image (`disk.raw`) packaged for import, with UEFI
  direct systemd-boot and cloud-init.
- **System Installer (`bin/install.sh`)**: Installs Gentoo onto target storage using binary packages, with automatic GPT partitioning (DPS), LUKS2 encryption, TPM2 unlock, and Btrfs subvolumes.

## External Components

The pipeline integrates with four external components:

1. **Custom Ebuild Overlay**: Supplies target profiles, package masks, and custom ebuilds (HEAD commits must be GPG-signed).
2. **Ansible Repository**: Executed via `ansible-pull` by `bin/install.sh` for post-installation system configuration.
3. **S3 Object Storage**: Hosts binary packages (`binpkgs/<profile>/`) and published `stage3` archives.
4. **storage.to**: Used for transient (7-day) uploads of live installer ISOs, Google Cloud custom disk images, their detached PGP signatures (`.sig`), and automatic Portage build failure logs.

## Quick Start

### 1. Configuration

Copy `.env.example` to `.env` and configure your repository URLs, PGP signing keys, Secure Boot credentials, and S3 credentials:

```bash
cp .env.example .env
chmod 0600 .env
```

### 2. Common Usage

All scripts require `root` privileges and support `-h` / `--help` for option details:

```bash
# Bootstrap from an official Gentoo seed stage
sudo ./bin/bootstrap.sh \
  --arch amd64 \
  --name stage3-amd64-systemd \
  --profile "custom-overlay:amd64/x86-64-v3/base" \
  --workaround

# Or bootstrap using an existing custom stage3 as seed
sudo ./bin/bootstrap.sh \
  --profile "custom-overlay:amd64/x86-64-v3/gnome" \
  --seed-stage \
  "custom-overlay:amd64/x86-64-v3/base"

# Update base system packages and refresh the stage3 archive
sudo ./bin/update.sh --profile "custom-overlay:amd64/x86-64-v3/base"

# Build additional binary packages
sudo ./bin/build.sh \
  --packages "app-admin/ansible sys-kernel/gentoo-kernel" \
  --profile "custom-overlay:amd64/x86-64-v3/base"

# Build live installer ISO
sudo ./bin/build-install.sh --profile "custom-overlay:amd64/x86-64-v3/base"

# Build Google Cloud custom image
sudo ./bin/build-gce.sh --profile "custom-overlay:amd64/x86-64-v3/base"

# Install target system from booted live media
sudo install.sh \
  --drive /dev/nvme0n1 \
  --encrypt \
  --profile "custom-overlay:amd64/x86-64-v3/base" \
  --swap 16
```

## Downstream Gentoo Mirror (GitHub Actions Only)

To prevent ebuild tree desynchronization between system updates, package builds,
and installed systems, a controlled downstream fork of `gentoo-mirror/gentoo`
can be maintained (e.g. `<owner>/gentoo-mirror`).

This repository includes a standalone, GitHub-only workflow (`Sync`, located at
[`.github/workflows/sync.yml`](.github/workflows/sync.yml)) to fast-forward the
fork on demand without local dependencies:

- **Trigger**: Manually dispatched (`workflow_dispatch`) via GitHub Actions.
- **Authentication**: Requires a `SYNC_FORK_PAT` repository secret with write
  access to the fork (`${{ github.repository_owner }}/gentoo-mirror`).
- **Operation**: Runs `gh repo sync --force` against `gentoo-mirror/gentoo`
  (branch `stable`).

## CI/CD Workflows (GitHub Actions Only)

The `Build` ([`.github/workflows/build.yml`](.github/workflows/build.yml)) and
`Update` ([`.github/workflows/update.yml`](.github/workflows/update.yml))
workflows run on GitHub-hosted runners using repository variables:

- **`PROFILES`**: Newline-separated list of target profiles executed in
  parallel via matrix.
- **`BUILD_PRE_PACKAGES`**: Optional. Same format as `BUILD_PACKAGES`. When set,
  these atoms are emerged first in a separate `emerge` call before `BUILD_PACKAGES`.
  Useful for toolchain components that must be installed before dependents are built.
- **`BUILD_PACKAGES`**: Newline- or space-separated list of package atoms for
  `build.yml`. Inline `#` comments are supported and stripped at runtime.

Workflows enforce a 5.5-hour execution timer (`--timeout="330m"`), automatically
checkpointing live `emerge` process trees mid-build via CRIU (`criu dump` /
`criu restore`), uploading the intermediate state to S3, and resuming timed-out
profiles across up to 4 attempts. Stale snapshots are pruned automatically;
setting a 1–2 day expiration lifecycle rule on `resumes/` in S3 is recommended.

## Google Cloud Custom Images (Secure Boot)

The `Build GCE Image` workflow
([`.github/workflows/build-gce.yml`](.github/workflows/build-gce.yml)) and
`bin/build-gce.sh` produce compressed raw disk archives (`disk.raw` in
`.tar.gz`) configured with direct `systemd-boot` and `cloud-init`.

To import the image into Google Cloud and run it with Shielded VM Secure Boot:

1. Upload the built `.tar.gz` archive to a Google Cloud Storage bucket:
   ```bash
   gcloud storage cp gce-<profile>-<date>.tar.gz gs://<bucket-name>/
   ```
2. Create the custom image with UEFI and Shielded VM custom Secure Boot:
   ```bash
   gcloud compute images create <image-name> \
     --source-uri="gs://<bucket-name>/gce-<profile>-<date>.tar.gz" \
     --guest-os-features="UEFI_COMPATIBLE,GVNIC,VIRTIO_SCSI_MULTIQUEUE" \
     --signature-database-file="Secure Boot Certificate.der"
   ```
3. Launch a VM instance with Shielded VM Secure Boot enabled:
   ```bash
   gcloud compute instances create <instance-name> \
     --image=<image-name> \
     --shielded-secure-boot \
     --shielded-vtpm \
     --shielded-integrity-monitoring
   ```

Because the bootloader uses direct `systemd-boot` signed by `SECUREBOOT_KEY`,
the UEFI firmware validates `BOOTX64.EFI` directly against your custom signature
database without requiring Microsoft 3rd-party UEFI CA certificates. On first
boot, `cloud-init` automatically expands the root partition, resizes Btrfs to
the full disk capacity, generates SSH host keys, and configures instance
metadata.

## Attribution

- `bin/build.py` is derived from `targets/stage1/build.py` in [Gentoo Catalyst](https://gitweb.gentoo.org/proj/catalyst.git/) (Copyright 1999-2024 Gentoo Authors) and is licensed under `GPL-2.0-or-later`.
