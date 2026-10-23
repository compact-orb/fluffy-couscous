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

cli_parse "${@}"
readonly PROFILE

check_root
check_required_commands
readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"

configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

mount_repos "${STAGE_DIR}"

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

unmount_repos

remove_portage_configuration "${STAGE_DIR}"

upload_mounted_binary_packages "${STAGE_DIR}" "${PROFILE}"
unmount_binary_packages

publish_stage_archive "${STAGE_DIR}" "${PROFILE}" "stage3"

force_remove "${STAGE_DIR}"
