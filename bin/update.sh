#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    echo "You must be root to run this script."
    exit 1
fi

if (( $# < 1 )); then
    echo "Usage: $0 <profile>"
    exit 1
fi

required_commands=(
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

profile="${1}"
stage_dir="${BUILD_DIR}/stage"

fetch_project_stage "${stage_dir}" "${profile}" "stage3"

download_ebuild_repositories

configure_portage "${stage_dir}" "${profile}" "stage3"

mount_repos_in_chroot "${stage_dir}"

install_portage_gpg_key "${stage_dir}"
install_secureboot_keys "${stage_dir}"

mount_binary_packages "${stage_dir}" "${profile}"

chroot_run "${stage_dir}" '
    emerge --deep --jobs="$(nproc)" --newuse --update @system
    emerge --depclean
    emerge --jobs="$(nproc)" @preserved-rebuild
    emerge --depclean
    '

unmount_repos_in_chroot

remove_portage_configuration "${stage_dir}"

upload_mounted_binary_packages "${stage_dir}" "${profile}"
unmount_binary_packages

publish_stage_archive "${stage_dir}" "${profile}" "stage3"

force_remove "${stage_dir}"
