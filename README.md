# fluffy-couscous

[![CodeFactor](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous/badge)](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous)

Automated Gentoo `stage3` builder, binary package host, UEFI Secure Boot live
ISO generator, and system installer.

## Overview

This project builds, updates, and installs custom Gentoo systems without Gentoo
Catalyst:

- **Bootstrap (`bin/bootstrap.sh`)**: Builds an initial base `stage3` archive
  and binary package repository from an official Gentoo seed stage or a custom
  `stage3` archive.
- **System Updates (`bin/update.sh`)**: Updates `@system` packages, rebuilds
  preserved libraries, and refreshes the base `stage3` archive on S3.
- **Package Builds (`bin/build.sh`)**: Builds target packages inside the
  profile's `stage3` and syncs new binary packages to S3.
- **Live Installer ISO (`bin/build-install.sh`)**: Builds a bootable UEFI Secure
  Boot live installer ISO containing the installer scripts and binary
  repository configs.
- **Google Cloud Image (`bin/build-gce.sh`)**: Builds a Google Compute Engine
  (GCE) custom raw disk image (`disk.raw`) packaged for import, with UEFI direct
  `systemd-boot`.
- **System Installer (`bin/install.sh`)**: Installs Gentoo onto target storage
  using binary packages, with automatic GPT partitioning (DPS), LUKS2
  encryption, TPM2 unlock, and Btrfs subvolumes.

## External Components

This project uses four external services or repositories:

1. **Custom Ebuild Overlay**: Supplies target profiles, package masks, and
   custom ebuilds (`HEAD` commits must be GPG-signed unless marked with
   `no-verify`).
2. **Ansible Repository**: Run with `ansible-pull` by `bin/install.sh` and
   `bin/build-gce.sh` to finish system setup.
3. **S3 Object Storage**: Hosts binary packages (`binpkgs/<profile>/`) and
   published `stage3` archives.
4. **storage.to**: Used for temporary (7-day) uploads of live installer ISOs,
   GCE disk images, their detached PGP signatures (`.sig`), and Portage build
   failure logs.

## Quick Start

### 1. Configuration

Non-secret configuration is tracked directly in the repository:

- **`config/env`**: Mirror URL, ebuild/binary package repositories, Ansible
  repository URL, S3 endpoint/region/bucket/access key ID, and `IMAGE_USER`.
- **`config/profiles`**: Target profiles and their package sets
  (`<repo:profile/path> <package_set ...>`). Used by `bin/build.sh` and the
  `Build` / `Update` GitHub Actions workflows.
- **`config/packages/`**: Plain-text package lists (one atom per line, `#`
  comments supported). `config/packages/pre` is emerged first in a separate
  `emerge` call before the profile's configured sets (`common`, `goldmont-plus`,
  `x86-64-v3`, etc.).
- **`keys/`**: Bundled public PGP keys (`*.asc`, including `signing.asc` for
  binary package and stage verification and `repo.asc` for Git commit
  verification) and the Secure Boot public certificate (`secureboot.pem`).

Secrets stay out of git. For local runs, copy `.env.example` to `.env` and fill
in your private keys and credentials:

```bash
cp .env.example .env
chmod 0600 .env
```

### 2. Common Usage

All scripts require `root` privileges and support `-h` / `--help` for option
details:

```bash
# Bootstrap from an official Gentoo seed stage (AMD64)
sudo ./bin/bootstrap.sh \
  --arch amd64 \
  --name stage3-amd64-systemd \
  --profile "automatic-journey:amd64/x86-64-v3/gnome" \
  --workaround

# Or bootstrap for ARM64 (defaults to stage3-arm64-systemd automatically)
sudo ./bin/bootstrap.sh \
  --profile "automatic-journey:arm64/armv8.2-a/gnome" \
  --workaround

# Or bootstrap using an existing custom stage3 as seed
sudo ./bin/bootstrap.sh \
  --profile "automatic-journey:amd64/x86-64-v3/gnome" \
  --seed-stage \
  "automatic-journey:amd64/x86-64-v3/base"

# Update base system packages and refresh the stage3 archive
sudo ./bin/update.sh --profile "automatic-journey:amd64/x86-64-v3/gnome"
sudo ./bin/update.sh --profile "automatic-journey:arm64/armv8.2-a/gnome"

# Build the profile's configured package sets from config/
sudo ./bin/build.sh --profile "automatic-journey:amd64/x86-64-v3/gnome"
sudo ./bin/build.sh --profile "automatic-journey:arm64/armv8.2-a/gnome"

# Or build a custom list of packages (skips config/packages/*)
sudo ./bin/build.sh \
  --packages "app-admin/ansible sys-kernel/gentoo-kernel" \
  --profile "automatic-journey:amd64/x86-64-v3/gnome"

# Build live installer ISO
sudo ./bin/build-install.sh --profile "automatic-journey:amd64/x86-64-v3/gnome"
sudo ./bin/build-install.sh --profile "automatic-journey:arm64/armv8.2-a/gnome"

# Build Google Cloud custom image
sudo ./bin/build-gce.sh --profile "automatic-journey:amd64/x86-64-v3/gnome"
sudo ./bin/build-gce.sh --profile "automatic-journey:arm64/armv8.2-a/gnome"

# Install target system from booted live media
sudo install.sh \
  --drive /dev/nvme0n1 \
  --encrypt \
  --profile "automatic-journey:amd64/x86-64-v3/gnome" \
  --swap 16
```

## Downstream Gentoo Mirror (GitHub Actions Only)

To keep the ebuild tree consistent across system updates, package builds, and
installed systems, you can maintain your own fork of `gentoo-mirror/gentoo` (for
example, `<owner>/gentoo-mirror`).

The `Sync` workflow ([`.github/workflows/sync.yml`](.github/workflows/sync.yml))
updates your forks on demand in GitHub Actions:

- **Trigger**: Manually dispatched (`workflow_dispatch`) via GitHub Actions.
- **Authentication**: Requires a `SYNC_FORK_PAT` repository secret with write
  access to the forks under `${{ github.repository_owner }}`.
- **Operation**: Runs `gh repo sync --force` for `gentoo-mirror` (`stable`),
  `guru` (`master`), and `steam-overlay` (`master`).

## CI/CD Workflows (GitHub Actions Only)

The `Build` ([`.github/workflows/build.yml`](.github/workflows/build.yml)) and
`Update` ([`.github/workflows/update.yml`](.github/workflows/update.yml))
workflows run on GitHub-hosted runners using the profiles in `config/profiles`
and package sets in `config/packages/` (no GitHub Actions repository variables
are used; only repository secrets such as `SIGNING_KEY`, `SECUREBOOT_KEY`,
`S3_SECRET_ACCESS_KEY`, `S3_RO_SECRET_ACCESS_KEY`, `STORAGETO_KEY`,
`IMAGE_SSH_PUBLIC_KEY`, and `SYNC_FORK_PAT`).

Workflows set a 5.5-hour timer (`--timeout="330m"`) by default. When a build
times out, CRIU (`criu dump` / `criu restore`) saves the running `emerge`
processes, uploads the intermediate Btrfs image to S3, and resumes on the next
job (up to 8 attempts for `Build` and `Bootstrap`, and up to 4 attempts for
`Update`). Old snapshots are deleted automatically, though setting a 1–2 day
expiration rule on `resumes/` in S3 is recommended.

## Google Cloud Custom Images (Secure Boot)

The `Build GCE` workflow
([`.github/workflows/build-gce.yml`](.github/workflows/build-gce.yml)) and
`bin/build-gce.sh` produce compressed raw disk archives (`disk.raw` in
`.tar.gz`) configured with direct `systemd-boot`.

To import the image into Google Cloud and run it with Shielded VM Secure Boot:

1. Upload the built `.tar.gz` archive to a Google Cloud Storage bucket:

   ```bash
   gcloud storage cp gce-<profile>-<date>.tar.gz gs://<bucket-name>/
   ```

2. Create the custom image with UEFI and Shielded VM custom Secure Boot (add
   `--architecture=ARM64` when importing ARM64 images):

   ```bash
   # For x86_64:
   gcloud compute images create <image-name> \
     --source-uri="gs://<bucket-name>/gce-<profile>-<date>.tar.gz" \
     --guest-os-features="GVNIC,IDPF,UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE" \
     --signature-database-file="Secure Boot Certificate.der"

   # For ARM64:
   gcloud compute images create <image-name> \
     --architecture=ARM64 \
     --source-uri="gs://<bucket-name>/gce-<profile>-<date>.tar.gz" \
     --guest-os-features="GVNIC,IDPF,UEFI_COMPATIBLE,VIRTIO_SCSI_MULTIQUEUE" \
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

Because `systemd-boot` is signed directly with `SECUREBOOT_KEY`, UEFI firmware
checks `BOOTX64.EFI` (or `BOOTAA64.EFI` on ARM64) against your custom signature
database without needing Microsoft third-party UEFI CA certificates.

## Attribution

- `bin/build.py` is derived from `targets/stage1/build.py` in [Gentoo Catalyst](https://gitweb.gentoo.org/proj/catalyst.git/) (Copyright 1999-2024 Gentoo Authors) and is licensed under `GPL-2.0-or-later`.
