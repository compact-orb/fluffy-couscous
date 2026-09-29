# Workarounds for preparing a non-LLVM seed for building a LLVM stage
# without taking the time to update the seed's portage configuration
# and re-merging the necessary packages.

create_file "${seed_dir}/etc/portage/package.use/clang-common" \
    "llvm-core/clang-common default-lld"
create_file "${seed_dir}/etc/portage/package.use/clang-linker-config" \
    "llvm-core/clang-linker-config default-lld"
create_file "${seed_dir}/etc/portage/package.use/clang-runtime" \
    "llvm-runtimes/clang-runtime default-lld polly"

chroot_run "${seed_dir}" '
    emerge --getbinpkg --jobs="$(nproc)" "llvm-core/clang" \
    "llvm-core/clang-common" "llvm-core/clang-linker-config" \
    "llvm-core/lld" "llvm-runtimes/clang-runtime"
    '

# Clang binary package might not have abi_x86_32 forced, which might mean
# that 32-bit symlinks were not created.
chroot_run "${seed_dir}" '
    LLVM_MAJOR=$(clang -dumpversion | cut --delimiter="." --fields="1")
    ln --force --symbolic "clang-${LLVM_MAJOR}" \
        "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang-${LLVM_MAJOR}"
    ln --force --symbolic "clang++-${LLVM_MAJOR}" \
        "/usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang++-${LLVM_MAJOR}"
    '

# Author's profile needs extra packages to be merged.
chroot_run "${seed_dir}" \
    'emerge --getbinpkg --jobs="$(nproc)" "net-misc/aria2"'

chroot_run "${seed_dir}" \
    'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update "@world"'

# The custom profile might disable binutils-plugin for LLVM. Since
# llvm-core/llvmgold requires binutils-plugin for LLVM, it has to be
# unmerged.
chroot_run "${seed_dir}" 'emerge --unmerge "llvm-core/llvmgold"'

remove_portage_configuration "${seed_dir}"

apply_portage_configuration "${seed_dir}" "${profile}" "stage1"

# Perl might hardcode the compiler, and since the seed was built with GCC,
# Perl deps within a package will use GCC even though the rest of the package
# is using Clang. This will result in LLVM flags being passed to GCC, resulting
# in a build failure. To avoid this, Perl is rebuilt.
chroot_run "${seed_dir}" 'emerge --jobs="$(nproc)" "dev-lang/perl"'
