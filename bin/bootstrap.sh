#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

shopt -s extglob

PROFILE="automatic-journey:amd64/llvm-libstdc++-hardened-systemd-optimize-x86-64-v3"
WORKDIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
OVERLAY_URL="https://github.com/compact-orb/automatic-journey.git"
GENTOO_MIRROR_URL="http://gentoo.mirrors.ovh.net/gentoo-distfiles"
SIGNING_KEY_BASE64="lFgEarKdRBYJKwYBBAHaRw8BAQdAASNi9QUTRl5irOA1FdH68+Ru3r1dHrMwrsovIGohuE4AAP91qBgCDnFSvhPmQTusA11MMaKDhjvMJq/UCvL1yupPLg9AtBZmbHVmZnktY291c2NvdXMgYmlucGtniK8EExYKAFcWIQSv9t+ujOw35gdpZiK0x3iYaEJjCwUCarKdRBsUgAAAAAAEAA5tYW51MiwyLjUrMS4xMiwyLDICGwMFCwkIBwICIgIGFQoJCAsCBBYCAwECHgcCF4AACgkQtMd4mGhCYwvJLQD/eKXPTPgrYfB43YSIrqI5Eu3Fnee1iwbhB7/smJzx8/8BAIotPe678eSr+LeT9g14XoPXY/xjp2GnZRqasHq/3WMH"

# -------- Set Up Repositories --------

mkdir --parents $WORKDIR/repos
git clone --depth 1 https://github.com/gentoo-mirror/gentoo.git "$WORKDIR/repos/gentoo"
OVERLAY_NAME="${OVERLAY_URL##*/}"; OVERLAY_NAME="${OVERLAY_NAME%.git}"
git clone --depth 1 $OVERLAY_URL "$WORKDIR/repos/$OVERLAY_NAME"

# -------- Set Up Seed --------

gpg --import keys/gentoo-release.asc

latest_seed_path=$(curl --silent \
$GENTOO_MIRROR_URL/releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt |
gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}')

latest_seed_hash=$(curl --silent \
$GENTOO_MIRROR_URL/releases/amd64/autobuilds/${latest_seed_path}.DIGESTS |
gpg --decrypt --quiet | awk -v path="$latest_seed_path" '
    BEGIN { sub(".*/", "", path) }
    /^# BLAKE2B/ { b=1; next }
    /^#/         { b=0 }
    b && $2 == path { print $1; exit }
')

latest_seed_filename=$(basename $latest_seed_path)

curl --output-dir /tmp --remote-name --silent \
$GENTOO_MIRROR_URL/releases/amd64/autobuilds/${latest_seed_path}

echo $latest_seed_hash /tmp/$latest_seed_filename |
b2sum --check --status

mkdir --parents $WORKDIR/seed

tar --extract --file=/tmp/$latest_seed_filename --directory=$WORKDIR/seed \
--preserve-permissions --numeric-owner --xattrs-include='*.*'

rm /tmp/$latest_seed_filename

cp --dereference /etc/resolv.conf $WORKDIR/seed/etc

mount --types proc /proc $WORKDIR/seed/proc
mount --rbind /sys $WORKDIR/seed/sys
mount --make-rslave $WORKDIR/seed/sys
mount --rbind /dev $WORKDIR/seed/dev
mount --make-rslave $WORKDIR/seed/dev
mount --bind /run $WORKDIR/seed/run
mount --make-slave $WORKDIR/seed/run

mkdir --parents $WORKDIR/seed/var/db/repos/gentoo
mount --bind $WORKDIR/repos/gentoo $WORKDIR/seed/var/db/repos/gentoo
mkdir --parents $WORKDIR/seed/var/db/repos/$OVERLAY_NAME
mount --bind $WORKDIR/repos/$OVERLAY_NAME $WORKDIR/seed/var/db/repos/$OVERLAY_NAME

echo "llvm-runtimes/clang-runtime default-lld polly" > $WORKDIR/seed/etc/portage/package.use/clang-runtime
echo "llvm-core/clang-common default-lld" > $WORKDIR/seed/etc/portage/package.use/clang-common
echo "llvm-core/clang-linker-config default-lld" > $WORKDIR/seed/etc/portage/package.use/clang-linker-config
echo "llvm-runtimes/clang-runtime default-lld" > $WORKDIR/seed/etc/portage/package.use/clang-runtime

mkdir --parents $WORKDIR/seed/var/tmp/portage
mount -t tmpfs -o size=50%,uid=250,gid=250,mode=775 tmpfs $WORKDIR/seed/var/tmp/portage

chroot $WORKDIR/seed /bin/bash --login -c "
emerge --jobs=$(nproc) --deep --getbinpkg --newuse --update @world llvm-core/clang \\
llvm-core/clang-common llvm-core/clang-linker-config llvm-core/lld \\
llvm-runtimes/clang-runtime net-misc/aria2
"

# -------- Build Stage1 --------

rm --force --recursive $WORKDIR/seed/etc/portage/!(make.profile)
cp --recursive $WORKDIR/portage/stage1/* $WORKDIR/seed/etc/portage

chroot $WORKDIR/seed /bin/bash --login -c "
eselect profile set $PROFILE
"

# Custom overlay profile specific fixes
# Portage evaluates build-time deps on the seed. The custom profile disables
# binutils-plugin for llvm, but the official stage3 came with llvm-core/llvmgold
# installed, which strictly requires llvm[binutils-plugin]
chroot $WORKDIR/seed /bin/bash --login -c "
emerge -C llvm-core/llvmgold
"
# Clang binary package might not have abi_x86_32 forced, which might mean that
# 32 bit symlinks were not created maybe? IDK.
chroot $WORKDIR/seed /bin/bash --login -c '
# Dynamically get the installed LLVM major version
LLVM_MAJOR=$(clang -dumpversion | cut -d. -f1)
ln -sf clang-${LLVM_MAJOR} /usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang-${LLVM_MAJOR}
ln -sf clang++-${LLVM_MAJOR} /usr/lib/llvm/${LLVM_MAJOR}/bin/i686-pc-linux-gnu-clang++-${LLVM_MAJOR}
'

mkdir --parents $WORKDIR/stage1

mkdir --parents $WORKDIR/seed/tmp/stage1
mount --bind $WORKDIR/stage1 $WORKDIR/seed/tmp/stage1

chroot $WORKDIR/seed /bin/bash --login -c "
USE=\"build\" emerge --root=/tmp/stage1 --oneshot --nodeps sys-apps/baselayout
"

cp $WORKDIR/bin/build.py $WORKDIR/seed/tmp

buildpkgs=$(chroot $WORKDIR/seed /bin/bash --login -c "/tmp/build.py")

chroot $WORKDIR/seed /bin/bash --login -c "
emerge --jobs=$(nproc) --root=/tmp/stage1 --implicit-system-deps=n --oneshot $buildpkgs
"

chroot $WORKDIR/seed /bin/bash --login -c "
echo 'C.UTF-8 UTF-8' > /etc/locale.gen

locale-gen --prefix /tmp/stage1
"

umount -l $WORKDIR/seed/dev{/shm,/pts,} $WORKDIR/seed/sys $WORKDIR/seed/proc $WORKDIR/seed/run
umount -l $WORKDIR/seed/var/db/repos/gentoo $WORKDIR/seed/var/db/repos/$OVERLAY_NAME
umount -l $WORKDIR/seed/var/tmp/portage
umount -l $WORKDIR/seed/tmp/stage1
# During testing, I had to run below again because just one did not completely
# remove the mount there when checking via `mount` I saw multiple mounts to that
# one loco. I do not know if I messed up or a quirk.
umount -l $WORKDIR/seed/tmp/stage1

# -------- Build Stage3 --------

# Should probably be a bind mount
cp --dereference /etc/resolv.conf $WORKDIR/stage1/etc

mount --types proc /proc $WORKDIR/stage1/proc
mount --rbind /sys $WORKDIR/stage1/sys
mount --make-rslave $WORKDIR/stage1/sys
mount --rbind /dev $WORKDIR/stage1/dev
mount --make-rslave $WORKDIR/stage1/dev
mount --bind /run $WORKDIR/stage1/run
mount --make-slave $WORKDIR/stage1/run

mkdir --parents $WORKDIR/stage1/var/db/repos/gentoo
mount --bind $WORKDIR/repos/gentoo $WORKDIR/stage1/var/db/repos/gentoo
mkdir --parents $WORKDIR/stage1/var/db/repos/$OVERLAY_NAME
mount --bind $WORKDIR/repos/$OVERLAY_NAME $WORKDIR/stage1/var/db/repos/$OVERLAY_NAME

mkdir --parents $WORKDIR/stage1/var/tmp/portage
mount -t tmpfs -o size=50%,uid=250,gid=250,mode=775 tmpfs $WORKDIR/stage1/var/tmp/portage

mkdir --parents $WORKDIR/stage1/etc/portage

cp --recursive $WORKDIR/portage/stage3/* $WORKDIR/stage1/etc/portage

chroot $WORKDIR/stage1 /bin/bash --login -c "
eselect profile set $PROFILE
"

# Create key
# gpg --batch --passphrase '' --quick-generate-key "fluffy-couscous binpkg" ed25519 sign 0
# Temporary for testing. Create new and protect for prod
# 1. Setup SIGNING keyring (used by root during binpkg creation - needs PRIVATE key)
chroot $WORKDIR/stage1 /bin/bash --login -c "
mkdir -p /var/lib/portage/gnupg-sign
chmod 0700 /var/lib/portage/gnupg-sign
echo '$private_key' | base64 --decode | gpg --homedir /var/lib/portage/gnupg-sign --batch --import
echo 'AFF6DFAE8CEC37E607696622B4C778986842630B:6:' | gpg --homedir /var/lib/portage/gnupg-sign --batch --import-ownertrust
gpg --homedir /var/lib/portage/gnupg-sign --batch --check-trustdb
"
# 2. Setup VERIFICATION keyring (used for installing binpkgs - only needs PUBLIC key)
chroot $WORKDIR/stage1 /bin/bash --login -c "
getuto
# Export only the PUBLIC key from the sign dir, and import it to the verify dir
gpg --homedir /var/lib/portage/gnupg-sign --export | gpg --homedir /etc/portage/gnupg --batch --import
echo 'AFF6DFAE8CEC37E607696622B4C778986842630B:6:' | gpg --homedir /etc/portage/gnupg --batch --import-ownertrust
gpg --homedir /etc/portage/gnupg --batch --check-trustdb
"

env -i HOME=/root TERM=$TERM PATH=$PATH \
chroot $WORKDIR/stage1 /bin/bash --login -c "
CONFIG_PROTECT=\"-*\" emerge --jobs=$(nproc) --emptytree @system
emerge --depclean
"

umount -l $WORKDIR/stage1/dev{/shm,/pts,} $WORKDIR/stage1/sys $WORKDIR/stage1/proc $WORKDIR/stage1/run
umount -l $WORKDIR/stage1/var/db/repos/gentoo $WORKDIR/stage1/var/db/repos/$OVERLAY_NAME
umount -l $WORKDIR/stage1/var/tmp/portage

rm --force --recursive $WORKDIR/stage1/etc/portage/!(make.profile)

tar --create --file=$WORKDIR/stage1.tar.zst --directory=$WORKDIR/stage1 \
    --preserve-permissions --numeric-owner --xattrs-include='*.*' \
    --use-compress-program="zstd -9 -T0 --long=31" \
    --exclude="./tmp/*" \
    --exclude="./var/tmp/*" \
    --exclude="./var/log/*" \
    --exclude="./etc/machine-id" \
    --exclude="./etc/resolv.conf" \
    --exclude="./root/*" \
    --exclude="./var/lib/portage/gnupg-sign" \
    --exclude="./var/cache/*" \
    --exclude="./var/lib/systemd/catalog/database" \
    --exclude="./var/lib/portage/gnupg-sign" \
    .
