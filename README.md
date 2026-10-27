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

## CI/CD Workflow Configuration (GitHub Actions Only)

The `Build` ([`.github/workflows/build.yml`](.github/workflows/build.yml)) and
`Update` ([`.github/workflows/update.yml`](.github/workflows/update.yml))
workflows are configured using repository variables (`vars`):

- **`PROFILES`**: Newline-separated list of profiles to process in parallel
  (e.g. `automatic-journey:amd64/x86-64-v3/base`). The workflow converts this
  list into a dynamic GitHub Actions matrix.
- **`BUILD_PACKAGES`**: Space-separated list of package atoms to build in
  `build.yml` (e.g. `app-admin/ansible sys-kernel/gentoo-kernel`).

### Timeout Resumption & Storage Management

To prevent builds from being aborted mid-way by the GitHub Actions 6-hour runner
limit, `build.sh` and `update.sh` include an internal execution timer
(`--timeout="330m"`) and multi-attempt resumption architecture:

1. **Graceful Timeout**: At 5 hours 30 minutes, `emerge` receives `SIGTERM`,
   allowing Portage to finalize disk writes and record its resume state in
   `/var/cache/edb/resume`.
2. **Intermediate Snapshots**: Completed binary packages are uploaded to S3,
   and an intermediate snapshot is archived to
   `:s3:${S3_BUCKET_NAME}/resumes/stage3-<profile>-resume-<run_id>.tar.zst`
   with a detached GPG signature.
3. **Chained Resumption**: The workflow automatically chains up to 4 attempts.
   Between attempts, an intermediate checker job inspects S3 and triggers the
   next attempt matrix *only* for profiles that timed out, invoking the script
   with `--resume` (`emerge --resume`).
4. **Storage Leak Prevention**:
   - **On Success**: `clear_resume_stage` deletes the snapshot immediately once
     all packages finish.
   - **Workflow Cleanup**: A dedicated `cleanup` job (`if: always()`) purges
     any run-scoped snapshots upon workflow completion.
   - **Aging Garbage Collection**: At the start of each run, snapshots older
     than 24 hours are pruned from S3.
   - **S3 Bucket Lifecycle Rule**: An object expiration lifecycle rule
     (1–2 days) should be configured on the `resumes/` prefix in the S3 bucket.

## Attribution

- `bin/build.py` is derived from `targets/stage1/build.py` in [Gentoo Catalyst](https://gitweb.gentoo.org/proj/catalyst.git/) (Copyright 1999-2024 Gentoo Authors) and is licensed under `GPL-2.0-or-later`.
