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

download_ebuild_repositories

download_extract_latest_gentoo_autobuild "${seed_dir}" \
    "${seed_architecture}" "${seed_name}"

configure_ebuild_repositories "${seed_dir}"

mount_ebuild_repositories "${seed_dir}"

mount_chroot_filesystems "${seed_dir}"

if [[ "${4}" -eq "workaround" ]]; then
    # Workarounds for preparing a non-LLVM seed for building a LLVM stage
    # without taking the time to update the seed's portage configuration
    # and re-merging the necessary packages.

    create_file "${seed_dir}/etc/portage/package.use/clang-common" \
        "llvm-core/clang-common default-lld"
    create_file "${seed_dir}/etc/portage/package.use/clang-linker-config" \
        "llvm-core/clang-linker-config default-lld"
    create_file "${seed_dir}/etc/portage/package.use/clang-runtime" \
        "llvm-runtimes/clang-runtime default-lld polly"
    
    chroot "${seed_dir}" /usr/bin/bash --login -c '
        emerge --getbinpkg --jobs="$(nproc)" "llvm-core/clang" \
        "llvm-core/clang-common" "llvm-core/clang-linker-config" \
        "llvm-core/lld" "llvm-runtimes/clang-runtime"
        '

    # The custom profile might disable binutils-plugin for LLVM. Since
    # llvm-core/llvmgold requires binutils-plugin for LLVM, it has to be
    # unmerged.
    chroot "${seed_dir}" /usr/bin/bash --login -c \
        'emerge --unmerge "llvm-core/llvmgold"'

    # Clang binary package might not have abi_x86_32 forced, which might mean
    # that 32-bit symlinks were not created.
    chroot "${seed_dir}" /usr/bin/bash --login -c '
        LLVM_MAJOR=$(clang -dumpversion | cut --delimiter="." --fields="1")
        ln --force --symbolic "clang-${LLVM_MAJOR}" \
            "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang-${LLVM_MAJOR}"
        ln --force --symbolic "clang++-${LLVM_MAJOR}" \
            "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang++-${LLVM_MAJOR}"
        '

    # Author's profile needs extra packages to be merged.
    chroot "${seed_dir}" /usr/bin/bash --login -c \
        'emerge --getbinpkg --jobs="$(nproc)" "net-misc/aria2"'

    chroot "${seed_dir}" /usr/bin/bash --login -c \
        'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update "@world"'

    remove_portage_configuration "${seed_dir}"

    apply_portage_configuration "${seed_dir}" "${profile}" "stage1"
else
    remove_portage_configuration "${seed_dir}"

    apply_portage_configuration "${seed_dir}" "${profile}" "stage1"

    chroot "${seed_dir}" /usr/bin/bash --login -c \
        'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update "@world"'
fi

create_directory "${stage_dir}"

create_directory "${seed_stage_bind_dir}"

mount --bind "${seed_dir}" "${seed_stage_bind_dir}"

chroot "${seed_dir}" /usr/bin/bash --login -c '
    USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
    "sys-apps/baselayout"
    '

copy_file "${work_dir}/bin/build.py" "${seed_dir}/tmp/build.py"

chroot "${seed_dir}" /usr/bin/bash --login -c '
    buildpkgs=$(/tmp/build.py)
    emerge --implicit-system-deps="n" --jobs="$(nproc)" --oneshot \
    --root="/tmp/stage" "${buildpkgs}"
    locale-gen --prefix "/tmp/stage"
    '

umount "${seed_stage_bind_dir}"

unmount_chroot_filesystems "${seed_dir}"

unmount_ebuild_repositories "${seed_dir}"

force_remove "${seed_dir}"

create_directory "${stage_dir}/etc/portage"

configure_ebuild_repositories "${stage_dir}"

mount_ebuild_repositories "${stage_dir}"

apply_portage_configuration "${stage_dir}" "${profile}" "stage3"

mount_chroot_filesystems "${stage_dir}"
