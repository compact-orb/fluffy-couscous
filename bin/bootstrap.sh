#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

gpg --import keys/gentoo-release.asc

latest_stage3_path=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt |
gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}')

latest_stage3_hash=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_stage3_path}.DIGESTS |
gpg --decrypt --quiet | awk -v path="$latest_stage3_path" '
  BEGIN { sub(".*/", "", path) }
  /^# BLAKE2B/ { b=1; next }
  /^#/         { b=0 }
  b && $2 == path { print $1; exit }
')

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

mkdir --parents /mnt/gentoo/etc/portage/patches/dev-util/catalyst
cp --recursive patches/* /mnt/gentoo/etc/portage/patches/dev-util/catalyst/

chroot /mnt/gentoo /bin/bash --login -c "
emerge-webrsync

echo 'dev-util/catalyst **' > /etc/portage/package.accept_keywords/catalyst
echo 'sys-apps/util-linux python' > /etc/portage/package.use/util-linux
echo 'sys-boot/grub grub_platforms_efi-32' > /etc/portage/package.use/grub

emerge --getbinpkg --quiet app-eselect/eselect-repository dev-util/catalyst
"

latest_snapshot_hash=$(curl --silent \
https://distfiles.gentoo.org/snapshots/squashfs/gentoo-current.sha512sum.txt |
gpg --decrypt --quiet | awk '$2 == "gentoo-current.xz.sqfs" {print $1; exit}')

mkdir --parents /mnt/gentoo/var/tmp/catalyst/snapshots

curl --output-dir /mnt/gentoo/var/tmp/catalyst/snapshots --remote-name --silent \
https://distfiles.gentoo.org/snapshots/squashfs/gentoo-current.xz.sqfs

echo $latest_snapshot_hash /mnt/gentoo/var/tmp/catalyst/snapshots/gentoo-current.xz.sqfs |
sha512sum --check --status

latest_catalyst_stage3_path=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt |
gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}')

latest_catalyst_stage3_hash=$(curl --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_catalyst_stage3_path}.DIGESTS |
gpg --decrypt --quiet | awk -v path="$latest_catalyst_stage3_path" '
  BEGIN { sub(".*/", "", path) }
  /^# BLAKE2B/ { b=1; next }
  /^#/         { b=0 }
  b && $2 == path { print $1; exit }
')

latest_catalyst_stage3_filename=$(basename $latest_catalyst_stage3_path)

mkdir --parents /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey

curl --output /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-desktop-systemd.tar.xz --silent \
https://distfiles.gentoo.org/releases/amd64/autobuilds/${latest_catalyst_stage3_path}

echo $latest_catalyst_stage3_hash /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-desktop-systemd.tar.xz |
b2sum --check --status

mkdir --parents /mnt/gentoo/tmp/seed

tar --directory=/mnt/gentoo/tmp/seed --extract \
--file=/mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-desktop-systemd.tar.xz \
--numeric-owner --xattrs-include='*.*'

rm /mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-desktop-systemd.tar.xz

rm --force /mnt/gentoo/tmp/seed/etc/resolv.conf
cp --dereference /etc/resolv.conf /mnt/gentoo/tmp/seed/etc/

mount --types proc /proc /mnt/gentoo/tmp/seed/proc
mount --rbind /sys /mnt/gentoo/tmp/seed/sys
mount --make-rslave /mnt/gentoo/tmp/seed/sys
mount --rbind /dev /mnt/gentoo/tmp/seed/dev
mount --make-rslave /mnt/gentoo/tmp/seed/dev
mount --bind /run /mnt/gentoo/tmp/seed/run
mount --make-slave /mnt/gentoo/tmp/seed/run

mkdir --parents /mnt/gentoo/tmp/seed/var/db/repos/gentoo
mount --bind /mnt/gentoo/var/db/repos/gentoo /mnt/gentoo/tmp/seed/var/db/repos/gentoo

chroot /mnt/gentoo/tmp/seed /bin/bash --login -c "
mkdir --parents /etc/portage/package.use
echo 'llvm-runtimes/clang-runtime polly' > /etc/portage/package.use/clang-runtime

emerge --getbinpkg --quiet app-arch/zstd llvm-core/lld llvm-runtimes/clang-runtime net-misc/aria2
env-update

rm --force --recursive /var/cache/distfiles /var/cache/binpkgs /var/tmp/portage
mkdir --parents /var/cache/distfiles /var/cache/binpkgs /var/tmp/portage
"

umount /mnt/gentoo/tmp/seed/var/db/repos/gentoo
umount /mnt/gentoo/tmp/seed/run
umount --recursive /mnt/gentoo/tmp/seed/dev
umount --recursive /mnt/gentoo/tmp/seed/sys
umount /mnt/gentoo/tmp/seed/proc

rm --force /mnt/gentoo/tmp/seed/etc/resolv.conf

XZ_OPT="-T0" tar --directory=/mnt/gentoo/tmp/seed --create --auto-compress \
--file=/mnt/gentoo/var/tmp/catalyst/builds/automatic-journey/latest-stage3-amd64-desktop-systemd.tar.xz \
--numeric-owner --xattrs-include='*.*' .

rm --recursive /mnt/gentoo/tmp/seed

mkdir --parents /mnt/gentoo/etc/portage/repos.conf
# Doing this before emerge-webrsync will break it becuase the repos are
# configured for git. Just keep that in mind.
cp --recursive ./portage/stage1/repos.conf/* /mnt/gentoo/etc/portage/repos.conf
git clone --depth 1 https://github.com/compact-orb/automatic-journey.git /mnt/gentoo/var/db/repos/automatic-journey

cp --recursive ../ /mnt/gentoo

rm /mnt/gentoo/etc/catalyst/catalyst.conf
echo "jobs = $(nproc)" > /mnt/gentoo/etc/catalyst/catalyst.conf
echo "envscript = "/etc/catalyst/catalystrc"" >> /mnt/gentoo/etc/catalyst/catalyst.conf
echo 'options = ["autoresume"]' >> /mnt/gentoo/etc/catalyst/catalyst.conf

echo 'EMERGE_DEFAULT_OPTS="--with-bdeps=y"' > /mnt/gentoo/etc/catalyst/catalystrc
echo 'BINPKG_GPG_SIGNING_KEY="AFF6DFAE8CEC37E607696622B4C778986842630B"' >> /mnt/gentoo/etc/catalyst/catalystrc
echo 'BINPKG_COMPRESS="zstd"' >> /mnt/gentoo/etc/catalyst/catalystrc
echo 'BINPKG_COMPRESS_FLAGS="-19 -T4 --long"' >> /mnt/gentoo/etc/catalyst/catalystrc
echo 'FEATURES="binpkg-request-signature binpkg-signing gpg-keepalive"' >> /mnt/gentoo/etc/catalyst/catalystrc
echo 'INSTALL_MASK="/boot"' >> /mnt/gentoo/etc/catalyst/catalystrc

# Create key
# gpg --batch --passphrase '' --quick-generate-key "fluffy-couscous binpkg" ed25519 sign 0
# Temporary for testing. Create new and protect for prod
private_key="lFgEarKdRBYJKwYBBAHaRw8BAQdAASNi9QUTRl5irOA1FdH68+Ru3r1dHrMwrsovIGohuE4AAP91qBgCDnFSvhPmQTusA11MMaKDhjvMJq/UCvL1yupPLg9AtBZmbHVmZnktY291c2NvdXMgYmlucGtniK8EExYKAFcWIQSv9t+ujOw35gdpZiK0x3iYaEJjCwUCarKdRBsUgAAAAAAEAA5tYW51MiwyLjUrMS4xMiwyLDICGwMFCwkIBwICIgIGFQoJCAsCBBYCAwECHgcCF4AACgkQtMd4mGhCYwvJLQD/eKXPTPgrYfB43YSIrqI5Eu3Fnee1iwbhB7/smJzx8/8BAIotPe678eSr+LeT9g14XoPXY/xjp2GnZRqasHq/3WMH"
chroot /mnt/gentoo /bin/bash --login -c "getuto"
echo $private_key | base64 --decode | gpg --homedir "/mnt/gentoo/root/.gnupg" --batch --import
chroot /mnt/gentoo /bin/bash --login -c "echo 'AFF6DFAE8CEC37E607696622B4C778986842630B:6:' | gpg --batch --import-ownertrust"

chroot /mnt/gentoo /bin/bash --login -c "
catalyst -f /fluffy-couscous/specs/stage1-amd64-llvm-libstdc++-hardened-systemd-optimize-x86-64-v3.spec
"

echo "jobs = $(nproc)" > /mnt/gentoo/etc/catalyst/catalyst.conf
echo "envscript = "/etc/catalyst/catalystrc"" >> /mnt/gentoo/etc/catalyst/catalyst.conf
echo 'options = ["autoresume", "pkgcache"]' >> /mnt/gentoo/etc/catalyst/catalyst.conf

chroot /mnt/gentoo /bin/bash --login -c "
catalyst -f /fluffy-couscous/specs/stage3-amd64-llvm-libstdc++-hardened-systemd-optimize-x86-64-v3.spec
"
