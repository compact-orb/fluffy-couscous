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

cp --dereference /etc/resolv.conf $WORKDIR/seed/etc

mount --types proc /proc $WORKDIR/seed/proc
mount --rbind /sys $WORKDIR/seed/sys
mount --make-rslave $WORKDIR/seed/sys
mount --rbind /dev $WORKDIR/seed/dev
mount --make-rslave $WORKDIR/seed/dev
mount --bind /run $WORKDIR/seed/run
mount --make-slave $WORKDIR/seed/run

mount --bind $WORKDIR/repos/gentoo $WORKDIR/seed/var/db/repos/gentoo
mkdir --parents $WORKDIR/seed/var/db/repos/$OVERLAY_NAME
mount --bind $WORKDIR/repos/$OVERLAY_NAME $WORKDIR/seed/var/db/repos/$OVERLAY_NAME

echo "llvm-runtimes/clang-runtime polly" > $WORKDIR/seed/etc/portage/package.use/clang-runtime

mount -t tmpfs -o size=50%,uid=250,gid=250,mode=775 tmpfs $WORKDIR/seed/var/tmp/portage

chroot $WORKDIR/seed /bin/bash --login -c "
emerge --deep --getbinpkg --newuse --update @world llvm-core/clang \\
llvm-core/lld llvm-runtimes/clang-runtime net-misc/aria2
"

# -------- Build Stage1 --------

rm --force --recursive $WORKDIR/seed/etc/portage/!(make.profile)
cp --recursive $WORKDIR/portage/stage1/* $WORKDIR/seed/etc/portage

chroot $WORKDIR/seed /bin/bash --login -c "
eselect profile set $PROFILE
"

mkdir --parents $WORKDIR/stage1

mount --bind $WORKDIR/stage1 $WORKDIR/seed/tmp/stage1

chroot $WORKDIR/seed /bin/bash --login -c "
USE=\"build\" emerge --root=/tmp/stage1 --oneshot --nodeps sys-apps/baselayout
"

cp $WORKDIR/bin/build.py $WORKDIR/seed/tmp

buildpkgs=$(chroot $WORKDIR/seed /bin/bash --login -c "/tmp/build.py")

chroot $WORKDIR/seed /bin/bash --login -c "
emerge --root=/tmp/stage1 --implicit-system-deps=n --oneshot $buildpkgs
"
