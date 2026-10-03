# This file is sourced by bootstrap.sh — do not execute directly.
if [[ -z "${SEED_DIR:-}" ]] || [[ -z "${PROFILE:-}" ]]; then
    log_error "workaround.sh must be sourced, and requires SEED_DIR and PROFILE to be set." 
    return 1 2>/dev/null || exit 1
fi

# Workarounds for preparing a non-LLVM seed for building a LLVM stage
# without taking the time to update the seed's portage configuration
# and re-merging the necessary packages.

create_file "${SEED_DIR}/etc/portage/package.use/clang-common" \
    "llvm-core/clang-common default-lld"
create_file "${SEED_DIR}/etc/portage/package.use/clang-linker-config" \
    "llvm-core/clang-linker-config default-lld"
create_file "${SEED_DIR}/etc/portage/package.use/clang-runtime" \
    "llvm-runtimes/clang-runtime default-lld polly"

chroot_run "${SEED_DIR}" '
    emerge --getbinpkg --jobs="$(nproc)" --quiet-build "llvm-core/clang" \
    "llvm-core/clang-common" "llvm-core/clang-linker-config" \
    "llvm-core/lld" "llvm-runtimes/clang-runtime"
    '

# Clang binary package might not have abi_x86_32 forced, which might mean
# that 32-bit symlinks were not created.
chroot_run "${SEED_DIR}" '
    LLVM_MAJOR=$(clang -dumpversion | cut --delimiter="." --fields="1")
    ln --force --symbolic "clang-${LLVM_MAJOR}" \
        "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang-${LLVM_MAJOR}"
    ln --force --symbolic "clang++-${LLVM_MAJOR}" \
        "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang++-${LLVM_MAJOR}"
    '

# Author's profile needs extra packages to be merged.
chroot_run "${SEED_DIR}" \
    'emerge --getbinpkg --jobs="$(nproc)" --quiet-build "net-misc/aria2"'

chroot_run "${SEED_DIR}" '
    emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --quiet-build \
        --update "@world"
    '

# The custom profile might disable binutils-plugin for LLVM. Since
# llvm-core/llvmgold requires binutils-plugin for LLVM, it has to be
# unmerged.
chroot_run "${SEED_DIR}" '
    CLEAN_DELAY=0 EMERGE_WARNING_DELAY=0 emerge --unmerge "llvm-core/llvmgold"
    '

remove_portage_configuration "${SEED_DIR}"

configure_portage "${SEED_DIR}" "${PROFILE}" "stage1"

# Perl might hardcode the compiler, and since the seed was built with GCC,
# Perl deps within a package will use GCC even though the rest of the package
# is using Clang. This will result in LLVM flags being passed to GCC, resulting
# in a build failure. To avoid this, Perl is rebuilt.
chroot_run "${SEED_DIR}" 'emerge --jobs="$(nproc)" "dev-lang/perl"'

# Update everything with the new profile to reduce the chance of issues.
chroot_run "${SEED_DIR}" \
    'emerge --deep --jobs="$(nproc)" --newuse --update "@world"'
