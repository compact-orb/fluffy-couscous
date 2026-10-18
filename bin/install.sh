#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    echo "You must be root to run this script." >&2
    exit 1
fi

if (( $# < 3 )); then
    echo "Usage: $0 <PROFILE> <INSTALL_DRIVE> <SWAP_SIZE_GIB> [ENCRYPT]" >&2
    exit 1
fi

# === CLI Arguments & Setup ===

readonly PROFILE="${1}"
readonly INSTALL_DRIVE="${2}"
readonly SWAP_SIZE_GIB="${3}"
readonly ENCRYPT="${4:-false}"
readonly INSTALL_MOUNT_DIR="${BUILD_DIR}/install"

readonly BOOT_MOUNT_OPTIONS="defaults,noatime"
readonly ROOT_MOUNT_OPTIONS="defaults,noatime,compress-force=zstd:3,discard=async"
readonly SWAP_MOUNT_OPTIONS="defaults,noatime"

required_commands=(
    "blkid"
    "btrfs"
    "dirname"
    "mkfs.btrfs"
    "mkfs.fat"
    "realpath"
    "sfdisk"
    "shred"
    "udevadm"
    "wipefs"
)

if [[ "${ENCRYPT}" == "true" ]]; then
    required_commands+=(
        "cryptsetup"
        "systemd-cryptenroll"
    )
fi

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

# === Prepare Drive ===

wipefs --all --force "${INSTALL_DRIVE}"

# TODO: Detect architecture and adapt root accordingly
sfdisk "${INSTALL_DRIVE}" <<EOF
label: gpt
size=1GiB, type=U
size=+, type="Linux root (x86-64)"
EOF

udevadm settle

if [[ "${INSTALL_DRIVE}" =~ [0-9]$ ]]; then
    part_prefix="${INSTALL_DRIVE}p"
else
    part_prefix="${INSTALL_DRIVE}"
fi

readonly BOOT_PARTITION="${part_prefix}1"
readonly ROOT_PARTITION="${part_prefix}2"
unset part_prefix

if [[ "${ENCRYPT}" == "true" ]]; then
    readonly RECOVERY_KEY="$(head -c 20 /dev/urandom | base32 | tr -d '=' | fold -w 5 | paste -sd '-' -)"
    luks_key_file="$(mktemp)"
    chmod 0600 "${luks_key_file}"
    printf "%s" "${RECOVERY_KEY}" > "${luks_key_file}"

    log_info "Formatting ${ROOT_PARTITION} with LUKS2"
    cryptsetup luksFormat \
        --batch-mode \
        --key-file "${luks_key_file}" \
        --type luks2 \
        "${ROOT_PARTITION}"

    log_info ================================================================
    log_info "EMERGENCY RECOVERY KEY: ${RECOVERY_KEY}"
    log_info "Please write this down and store it in a secure location!"
    log_info ================================================================

    log_info "Enrolling TPM2 device with PIN (PCR 7)..."
    systemd-cryptenroll \
        --tpm2-device="auto" \
        --tpm2-pcrs="7" \
        --tpm2-with-pin="yes" \
        --unlock-key-file="${luks_key_file}" \
        "${ROOT_PARTITION}"

    cryptsetup open \
        --key-file "${luks_key_file}" \
        "${ROOT_PARTITION}" \
        "root"

    shred --remove "${luks_key_file}"
    unset luks_key_file

    readonly ROOT_TARGET_DEV="/dev/mapper/root"
else
    readonly ROOT_TARGET_DEV="${ROOT_PARTITION}"
fi

mkfs.fat -F 32 "${BOOT_PARTITION}"
mkfs.btrfs --force "${ROOT_TARGET_DEV}"

udevadm settle

readonly BOOT_UUID="$(blkid --match-tag "UUID" --output "value" "${BOOT_PARTITION}")"
readonly ROOT_UUID="$(blkid --match-tag "UUID" --output "value" "${ROOT_TARGET_DEV}")"
readonly ROOT_PARTUUID="$(blkid --match-tag "PARTUUID" --output "value" "${ROOT_PARTITION}")"

btrfs_tmp_dir="$(mktemp --directory)"
mount --types "btrfs" "${ROOT_TARGET_DEV}" "${btrfs_tmp_dir}"
btrfs subvolume create "${btrfs_tmp_dir}/@"
btrfs subvolume create "${btrfs_tmp_dir}/@swap"

root_subvol_id="$(btrfs subvolume list "${btrfs_tmp_dir}" | awk '$NF == "@" {print $2}')"
btrfs subvolume set-default "${root_subvol_id}" "${btrfs_tmp_dir}"
unset root_subvol_id

umount "${btrfs_tmp_dir}"
remove_directory "${btrfs_tmp_dir}"
unset btrfs_tmp_dir

_active_install_mounts=()

create_directory "${INSTALL_MOUNT_DIR}"
managed_mount "_active_install_mounts" \
    --options "${ROOT_MOUNT_OPTIONS},subvol=@" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}"

create_directory "${INSTALL_MOUNT_DIR}/boot"
managed_mount "_active_install_mounts" \
    --options "${BOOT_MOUNT_OPTIONS}" \
    --types "vfat" \
    "${BOOT_PARTITION}" \
    "${INSTALL_MOUNT_DIR}/boot"

create_directory "${INSTALL_MOUNT_DIR}/swap"
managed_mount "_active_install_mounts" \
    --options "${SWAP_MOUNT_OPTIONS},subvol=@swap" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/swap"

btrfs filesystem mkswapfile --size "${SWAP_SIZE_GIB}g" \
    "${INSTALL_MOUNT_DIR}/swap/swapfile"

readonly RESUME_OFFSET="$(btrfs inspect-internal map-swapfile --resume-offset "${INSTALL_MOUNT_DIR}/swap/swapfile")"
log_info "Btrfs swapfile hibernation resume offset: ${RESUME_OFFSET}"

# === Configure Host Environment ===

configure_ebuild_repositories ""
mount_repos_in_chroot "" # Rename since it can be used outside chroot

remove_portage_configuration ""
configure_portage "" "${PROFILE}" "install"

# === Install Stage 1 ===

USE="build" emerge --nodeps --oneshot --root="${INSTALL_MOUNT_DIR}" \
    sys-apps/baselayout

buildpkgs=$(${WORK_DIR}/bin/build.py)
emerge --implicit-system-deps="n" --jobs="$(nproc)" --oneshot \
    --root="${INSTALL_MOUNT_DIR}" ${buildpkgs}
unset buildpkgs
locale-gen --prefix "${INSTALL_MOUNT_DIR}"

# === Clean Up Host Environment ===

unmount_repos_in_chroot

remove_portage_configuration ""

# === Install and Configure Gentoo ===

create_directory "${INSTALL_MOUNT_DIR}/etc/portage"

configure_portage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "install"

mount_repos_in_chroot "${INSTALL_MOUNT_DIR}"

# TODO: Install all the other stuff
chroot_run "${INSTALL_MOUNT_DIR}" '
    emerge --emptytree --jobs="$(nproc)" @system
    emerge --depclean
    '

remove_portage_configuration "${INSTALL_MOUNT_DIR}"

configure_ebuild_repositories "${INSTALL_MOUNT_DIR}"

# TODO: Configure binary package repos

# TODO: SystemD stuff

# TODO: fstab generation

# === Clean Up ===

managed_unmount_all "_active_install_mounts"

if [[ -b "/dev/mapper/root" ]]; then
    cryptsetup close "root"
fi
