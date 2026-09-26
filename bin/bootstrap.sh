#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

seed_architecture="${1}"
seed_name="${2}"
profile="${3}"

download_ebuild_repositories

download_extract_latest_gentoo_autobuild "${work_dir}/seed" \
    "${seed_architecture}" "${seed_name}"

configure_ebuild_repositories "${work_dir}/seed"

mount_ebuild_repositories "${work_dir}/seed"

mount_chroot_filesystems "${work_dir}/seed"

chroot "${work_dir}/seed" /usr/bin/bash --login -c \
    'emerge --jobs="$(nproc)" --deep --getbinpkg --newuse --update "@world"'

if [[ "${4}" -eq "workaround" ]]; then
    # Workarounds for preparing a non-LLVM seed for building a LLVM stage
    # without taking the time to update the seed's portage configuration
    # and re-merging the necessary packages.

    create_file "${work_dir}/seed/etc/portage/package.use/clang-common" \
        "llvm-core/clang-common default-lld"
    create_file "${work_dir}/seed/etc/portage/package.use/clang-linker-config" \
        "llvm-core/clang-linker-config default-lld"
    create_file "${work_dir}/seed/etc/portage/package.use/clang-runtime" \
        "llvm-runtimes/clang-runtime default-lld polly"
    
    chroot "${work_dir}/seed" /usr/bin/bash --login -c '
        emerge --jobs="$(nproc)" --getbinpkg "llvm-core/clang" \
        "llvm-core/clang-common" "llvm-core/clang-linker-config" \
        "llvm-core/lld" "llvm-runtimes/clang-runtime"
        '

    # The custom profile might disable binutils-plugin for LLVM. Since
    # llvm-core/llvmgold requires binutils-plugin for LLVM, it has to be
    # unmerged.
    chroot "${work_dir}/seed" /usr/bin/bash --login -c \
        'emerge --unmerge "llvm-core/llvmgold"'

    # Clang binary package might not have abi_x86_32 forced, which might mean
    # that 32-bit symlinks were not created.
    chroot "${work_dir}/seed" /usr/bin/bash --login -c '
        LLVM_MAJOR=$(clang -dumpversion | cut --delimiter="." --fields="1")
        ln --force --symbolic "clang-${LLVM_MAJOR}" \
            "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang-${LLVM_MAJOR}"
        ln --force --symbolic "clang++-${LLVM_MAJOR}" \
            "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang++-${LLVM_MAJOR}"
        '

    # Author's profile needs extra packages to be merged.
    chroot "${work_dir}/seed" /usr/bin/bash --login -c \
        'emerge --jobs="$(nproc)" --getbinpkg "net-misc/aria2"'
fi
