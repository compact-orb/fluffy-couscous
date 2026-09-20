#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Install systemd-container

gpg --import keys/gentoo-release.asc

latest_stage3_path=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt |
gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}' 2> /dev/null)

latest_stage3_hash=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_stage3_path}.DIGESTS |
gpg --decrypt --quiet | awk -v path="$latest_stage3_path" '
  BEGIN { sub(".*/", "", path) }
  /^# BLAKE2B/ { b=1; next }
  /^#/         { b=0 }
  b && $2 == path { print $1; exit }
' 2> /dev/null)

latest_stage3_filename=$(basename $latest_stage3_path)

curl --output-dir /tmp --remote-name --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_stage3_path}

echo $latest_stage3_hash /tmp/$latest_stage3_filename |
b2sum --check --status

mkdir --parents /mnt/gentoo

tar --directory=/mnt/gentoo --extract --file=/tmp/$latest_stage3_filename \
--numeric-owner --xattrs-include='*.*'

rm /tmp/$latest_stage3_filename

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --bind /mnt/gentoo /mnt/gentoo
mount --make-private /mnt/gentoo

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

chroot /mnt/gentoo /bin/bash --login -c "
emerge-webrsync

echo 'dev-util/catalyst ~amd64' > /etc/portage/package.accept_keywords/catalyst
echo 'sys-apps/util-linux python' > /etc/portage/package.use/util-linux
echo 'sys-boot/grub grub_platforms_efi-32' > /etc/portage/package.use/grub

emerge --getbinpkg --quiet app-eselect/eselect-repository dev-util/catalyst
"

latest_snapshot_hash=$(curl --silent \
https://distfiles.gentoo.org/snapshots/squashfs/gentoo-current.sha512sum.txt |
gpg --decrypt --quiet | awk '$2 == "gentoo-current.xz.sqfs" {print $1; exit}' 2> /dev/null)

mkdir --parents /mnt/gentoo/var/tmp/catalyst/snapshots

curl --output-dir /mnt/gentoo/var/tmp/catalyst/snapshots --remote-name --silent \
https://distfiles.gentoo.org/snapshots/squashfs/gentoo-current.xz.sqfs

echo $latest_snapshot_hash /mnt/gentoo/var/tmp/catalyst/snapshots/gentoo-current.xz.sqfs |
sha512sum --check --status

latest_catalyst_stage3_path=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-llvm-systemd.txt |
gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}' 2> /dev/null)

latest_catalyst_stage3_hash=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_catalyst_stage3_path}.DIGESTS |
gpg --decrypt --quiet | awk -v path="$latest_catalyst_stage3_path" '
  BEGIN { sub(".*/", "", path) }
  /^# BLAKE2B/ { b=1; next }
  /^#/         { b=0 }
  b && $2 == path { print $1; exit }
' 2> /dev/null)

latest_catalyst_stage3_filename=$(basename $latest_catalyst_stage3_path)

mkdir --parents /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey

curl --output /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-llvm-systemd.tar.xz --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_catalyst_stage3_path}

echo $latest_catalyst_stage3_hash /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-llvm-systemd.tar.xz |
b2sum --check --status

cp --recursive ../ /mnt/gentoo

git clone --depth=1 https://github.com/compact-orb/automatic-journey.git /mnt/gentoo/var/db/repos/automatic-journey

cp --recursive /mnt/gentoo/fluffy-couscous/portage/stage1/repos.conf/* /mnt/gentoo/etc/portage/repos.conf/

mkdir --parents /mnt/gentoo/etc/portage/repos.conf
cp --recursive /mnt/gentoo/fluffy-couscous/portage/stages/repos.conf/* /mnt/gentoo/etc/portage/repos.conf/

chroot /mnt/gentoo /bin/bash --login -c "
echo 'jobs = \$(nproc)' >> /etc/catalyst/catalyst.conf

catalyst -f /fluffy-couscous/specs/stage1-amd64-llvm-libstdc++-hardened-optimize-x86-64-v3-systemd.spec
"
