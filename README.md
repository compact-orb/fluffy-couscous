# fluffy-couscous

[![CodeFactor](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous/badge)](https://www.codefactor.io/repository/github/compact-orb/fluffy-couscous)

Automated Gentoo stage3 builder, binary package host, UEFI Secure Boot live ISO generator, and target system installer.

## Overview

This project provides a standalone toolchain that builds, updates, and installs custom Gentoo systems without using Gentoo Catalyst:

- **Bootstrap (`bin/bootstrap.sh`)**: Builds an initial base `stage3` archive and binary package repository from an official Gentoo seed stage.
- **System Updates (`bin/update.sh`)**: Updates `@system` packages, rebuilds preserved libraries, and refreshes the base `stage3` archive on S3.
- **Package Builds (`bin/build.sh`)**: Compiles target packages against the profile's `stage3` and syncs new binary packages to S3.
- **Live Installer ISO (`bin/build-install.sh`)**: Builds a bootable UEFI Secure Boot live installer ISO bundled with the installer and binary repository configs.
- **System Installer (`bin/install.sh`)**: Installs Gentoo onto target storage using binary packages, with automatic GPT partitioning (DPS), LUKS2 encryption, TPM2 unlock, and Btrfs subvolumes.

## External Components

The pipeline integrates with four external components:

1. **Custom Ebuild Overlay**: Supplies target profiles, package masks, and custom ebuilds (HEAD commits must be GPG-signed).
2. **Ansible Repository**: Executed via `ansible-pull` by `bin/install.sh` for post-installation system configuration.
3. **S3 Object Storage**: Hosts binary packages (`binpkgs/<profile>/`) and published `stage3` archives.
4. **storage.to**: Used for transient (7-day) uploads of live installer ISOs and automatic Portage build failure logs.

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
  --profile "custom-overlay:amd64/hardened-systemd" \
  --workaround

# Or bootstrap using an existing custom stage3 as seed
sudo ./bin/bootstrap.sh \
  --profile "custom-overlay:amd64/hardened-systemd" \
  --seed-stage \
  "custom-overlay:amd64/llvm-libstdc++-hardened-systemd-optimize-x86-64-v3"

# Update base system packages and refresh the stage3 archive
sudo ./bin/update.sh --profile "custom-overlay:amd64/hardened-systemd"

# Build additional binary packages
sudo ./bin/build.sh \
  --packages "app-admin/ansible sys-kernel/gentoo-kernel" \
  --profile "custom-overlay:amd64/hardened-systemd"

# Build live installer ISO
sudo ./bin/build-install.sh --profile "custom-overlay:amd64/hardened-systemd"

# Install target system from booted live media
sudo install.sh \
  --drive /dev/nvme0n1 \
  --encrypt \
  --profile "custom-overlay:amd64/hardened-systemd" \
  --swap 16
```

## Attribution

- `bin/build.py` is derived from `targets/stage1/build.py` in [Gentoo Catalyst](https://gitweb.gentoo.org/proj/catalyst.git/) (Copyright 1999-2024 Gentoo Authors) and is licensed under `GPL-2.0-or-later`.
