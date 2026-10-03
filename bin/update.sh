#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    log_error "You must be root to run this script."
    exit 1
fi

if (( $# < 1 )); then
    echo "Usage: $0 <PROFILE>"
    exit 1
fi

# === CLI Arguments & Setup ===

required_commands=(
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

readonly PROFILE="${1}"
readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"

download_ebuild_repositories

configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

mount_repos_in_chroot "${STAGE_DIR}"

install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"

mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

# === System Update ===

chroot_run "${STAGE_DIR}" '
    emerge --deep --jobs="$(nproc)" --newuse --update @system
    emerge --depclean
    emerge --jobs="$(nproc)" @preserved-rebuild
    emerge --depclean
    '

# === Cleanup & Upload ===

unmount_repos_in_chroot

remove_portage_configuration "${STAGE_DIR}"

upload_mounted_binary_packages "${STAGE_DIR}" "${PROFILE}"
unmount_binary_packages

publish_stage_archive "${STAGE_DIR}" "${PROFILE}" "stage3"

force_remove "${STAGE_DIR}"
