#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    echo "You must be root to run this script."
    exit 1
fi

if (( $# < 3 )); then
    echo "Usage: $0 <seed_architecture> <seed_name> <profile> [workaround]"
    exit 1
fi

required_commands=(
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

seed_architecture="${1}"
seed_name="${2}"
profile="${3}"
seed_dir="${BUILD_DIR}/seed"
stage_dir="${BUILD_DIR}/stage"
seed_stage_bind_dir="${seed_dir}/tmp/stage"

fetch_seed_stage "${seed_dir}" \
    "${seed_architecture}" "${seed_name}"

download_ebuild_repositories

configure_ebuild_repositories "${seed_dir}"
mount_repos_in_chroot "${seed_dir}"

if [[ "${4:-}" == "workaround" ]]; then
    source "${WORK_DIR}/lib/workaround.sh"
else
    remove_portage_configuration "${seed_dir}"
    configure_portage "${seed_dir}" "${profile}" "stage1"

    chroot_run "${seed_dir}" \
        'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update "@world"'
fi

create_directory "${stage_dir}"
create_directory "${seed_stage_bind_dir}"
bootstrap_mounts=()
managed_mount "bootstrap_mounts" --bind "${stage_dir}" "${seed_stage_bind_dir}"

chroot_run "${seed_dir}" '
    USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
    "sys-apps/baselayout"
    '

copy_file "${WORK_DIR}/bin/build.py" "${seed_dir}/tmp/build.py"
chroot_run "${seed_dir}" '
    buildpkgs=$(/tmp/build.py)
    emerge --implicit-system-deps="n" --jobs="$(nproc)" --oneshot \
    --root="/tmp/stage" ${buildpkgs}
    locale-gen --prefix "/tmp/stage"
    '

managed_unmount_all "bootstrap_mounts"

unmount_repos_in_chroot

force_remove "${seed_dir}"

create_directory "${stage_dir}/etc/portage"

configure_portage "${stage_dir}" "${profile}" "stage3"

mount_repos_in_chroot "${stage_dir}"

install_portage_gpg_key "${stage_dir}"
install_secureboot_keys "${stage_dir}"

chroot_run "${stage_dir}" '
    emerge --emptytree --jobs="$(nproc)" @system
    emerge --depclean
    '

unmount_repos_in_chroot

remove_portage_configuration "${stage_dir}"

upload_binary_packages "${stage_dir}" "${profile}"
publish_stage_archive "${stage_dir}" "${profile}" "stage3"

force_remove "${stage_dir}"
