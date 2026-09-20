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

systemd-nspawn --directory=/mnt/gentoo /bin/bash -c "
source /etc/profile

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

curl --output /mnt/gentoo/var/tmp/catalyst/builds/latest-stage3-amd64-llvm-systemd.tar.xz --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_catalyst_stage3_path}

echo $latest_catalyst_stage3_hash /tmp/$latest_catalyst_stage3_filename |
b2sum --check --status

cp --recursive . /mnt/gentoo

git clone --depth=1 https://github.com/compact-orb/automatic-journey.git /mnt/gentoo/usr/portage/repos/automatic-journey

systemd-nspawn --directory=/mnt/gentoo /bin/bash -c "
source /etc/profile

echo 'jobs = $(nproc)' >> /etc/catalyst/catalyst.conf

catalyst -f /fluffy-conscous/specs/stage1-amd64-llvm-libstc++-hardened-optimize-x86-64-v3-systemd.spec
"
