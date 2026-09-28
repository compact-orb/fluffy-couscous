#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

seed_architecture="${1}"
seed_name="${2}"
profile="${3}"
seed_dir="${work_dir}/seed"
stage_dir="${work_dir}/stage"
seed_stage_bind_dir="${seed_dir}/tmp/stage"

download_extract_latest_gentoo_autobuild "${seed_dir}" \
    "${seed_architecture}" "${seed_name}"

download_ebuild_repositories

configure_ebuild_repositories "${seed_dir}"
mount_ebuild_repositories "${seed_dir}"

if [[ "${4:-}" == "workaround" ]]; then
    source "${work_dir}/lib/workaround.sh"
else
    remove_portage_configuration "${seed_dir}"
    apply_portage_configuration "${seed_dir}" "${profile}" "stage1"

    chroot_run "${seed_dir}" \
        'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update "@world"'
fi

create_directory "${stage_dir}"
create_directory "${seed_stage_bind_dir}"
mount --bind "${stage_dir}" "${seed_stage_bind_dir}"

chroot_run "${seed_dir}" '
    USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
    "sys-apps/baselayout"
    '

copy_file "${work_dir}/bin/build.py" "${seed_dir}/tmp/build.py"
chroot_run "${seed_dir}" '
    buildpkgs=$(/tmp/build.py)
    emerge --implicit-system-deps="n" --jobs="$(nproc)" --oneshot \
    --root="/tmp/stage" "${buildpkgs}"
    echo "C.UTF-8 UTF-8" > /etc/locale.gen
    echo "LANG=C.UTF-8" > /tmp/stage/etc/env.d/02locale
    locale-gen --prefix "/tmp/stage"
    '

umount "${seed_stage_bind_dir}"

unmount_ebuild_repositories "${seed_dir}"

force_remove "${seed_dir}"

create_directory "${stage_dir}/etc/portage"
configure_ebuild_repositories "${stage_dir}"

mount_ebuild_repositories "${stage_dir}"

apply_portage_configuration "${stage_dir}" "${profile}" "stage3"

apply_portage_signing_key "${stage_dir}"

chroot_run "${stage_dir}" '
    emerge --emptytree --jobs=$(nproc) @system
    emerge --depclean
    '

unmount_ebuild_repositories "${stage_dir}"

upload_binary_packages "${stage_dir}" "${profile}"
upload_gentoo_root "${stage_dir}" "${profile}" "stage3"
