#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    log_error "You must be root to run this script."
    exit 1
fi

if (( $# < 2 )); then
    echo "Usage: $0 <profile> <packages>"
    exit 1
fi

required_commands=(
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

profile="${1}"
packages="${2}"
stage_dir="${BUILD_DIR}/stage"

fetch_project_stage "${stage_dir}" "${profile}" "stage3"

download_ebuild_repositories

configure_portage "${stage_dir}" "${profile}" "stage3"

mount_repos_in_chroot "${stage_dir}"

install_portage_gpg_key "${stage_dir}"
install_secureboot_keys "${stage_dir}"

mount_binary_packages "${stage_dir}" "${profile}"

chroot_run "${stage_dir}" '
    emerge --jobs="$(nproc)" app-portage/gentoolkit
    emerge --jobs="$(nproc)" '"${packages}"'
    revdep-rebuild -- --jobs="$(nproc)"
    emerge --depclean
    '

unmount_repos_in_chroot

remove_portage_configuration "${stage_dir}"

upload_mounted_binary_packages "${stage_dir}" "${profile}"
unmount_binary_packages

force_remove "${stage_dir}"
