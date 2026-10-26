#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "dirname"
    "realpath"
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/build.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_option "PACKAGES" "-P|--packages" \
    "Space-separated package atoms" 1
cli_define_option "USEPKG_EXCLUDE" "-e|--exclude" \
    "Binary packages to exclude" 0 ""

cli_parse "${@}"
readonly PROFILE PACKAGES USEPKG_EXCLUDE

check_root
check_required_commands

readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

# Fetch the existing base stage3 tarball from S3 and verify GPG signature.
fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"

# Configure Portage settings (USE flags, make.conf, masks) for stage3 build.
configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

# Bind-mount synced ebuild repositories into the stage chroot.
mount_repos "${STAGE_DIR}"

# Install package signing and Secure Boot keys inside chroot for binpkg build.
install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"

# Mount S3 binhost via rclone and layer a writable OverlayFS on binpkgs dir.
mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

# === Build Packages ===

# Emerge gentoolkit first to supply revdep-rebuild.sh, then emerge requested
# packages. Rebuild reverse dependencies from source (--usepkg=n) to fix
# broken linkage before cleaning unused dependencies.
chroot_run "${STAGE_DIR}" '
    emerge --jobs="$(nproc)" app-portage/gentoolkit
    emerge --jobs="$(nproc)" \
        --usepkg-exclude="'"${USEPKG_EXCLUDE}"'" '"${PACKAGES}"'
    revdep-rebuild.sh -- --jobs="$(nproc)" --usepkg=n
    emerge --depclean
    '

# === Cleanup & Upload ===

unmount_repos

remove_portage_configuration "${STAGE_DIR}"

# Sync the merged OverlayFS back to S3 so new binpkgs upload and removed
# binpkgs are pruned; unmount overlay and discard ephemeral build chroot
# without touching the baseline stage3 archive in S3.
upload_mounted_binary_packages "${STAGE_DIR}" "${PROFILE}"
unmount_binary_packages

force_remove "${STAGE_DIR}"
