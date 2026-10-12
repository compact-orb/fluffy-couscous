#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( EUID != 0 )); then
    echo "You must be root to run this script." >&2
    exit 1
fi

if (( $# < 1 )); then
    echo "Usage: $0 <PROFILE>"
    exit 1
fi

# === CLI Arguments & Setup ===

required_commands=(
    "dirname"
    "du"
    "mkfs.fat"
    "mksquashfs"
    "openssl"
    "realpath"
    "truncate"
    "xorriso"
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

readonly PROFILE="${1}"
readonly STAGE_DIR="${BUILD_DIR}/stage"
readonly ESP_MOUNT_DIR="${BUILD_DIR}/esp"
readonly ESP_IMG="${BUILD_DIR}/efiboot.img"
readonly ISO_DIR="${BUILD_DIR}/iso"
readonly ISO_VOLID="GENTOO_LIVE"

# === Environment Preparation ===

fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"

download_ebuild_repositories

configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

mount_repos_in_chroot "${STAGE_DIR}"

mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

create_directory "${STAGE_DIR}/boot/loader/entries"
create_file "${STAGE_DIR}/etc/portage/bashrc" 'export BOOT_MNT="/boot"'
create_empty_file "${STAGE_DIR}/etc/machine-id"

create_directory "${STAGE_DIR}/etc/dracut.conf.d"
create_file "${STAGE_DIR}/etc/dracut.conf.d/livecd.conf" 'hostonly="no"
add_dracutmodules+=" dmsquash-live "'

create_directory "${STAGE_DIR}/etc/kernel"
create_file "${STAGE_DIR}/etc/kernel/cmdline" \
    "root=live:CDLABEL=${ISO_VOLID} rd.live.overlay.overlayfs=1"

# === Live Environment Installation ===

chroot_run "${STAGE_DIR}" '
    emerge --buildpkg=n --jobs="$(nproc)" --usepkgonly \
        '"${INSTALLCD_PACKAGES//sys-kernel\/gentoo-kernel/}"'
    emerge --buildpkg=n --jobs="$(nproc)" --usepkgonly \
        "sys-kernel/gentoo-kernel"
    passwd --delete "root"
    systemctl enable "NetworkManager.service"
    /usr/lib/systemd/systemd-update-done
    '

# === Chroot Cleanup ===

unmount_repos_in_chroot

unmount_binary_packages

remove_portage_configuration "${STAGE_DIR}"

# === EFI System Partition Image ===

log_info "Populating EFI System Partition"

create_directory "${STAGE_DIR}/boot/EFI/BOOT"
copy_file "${STAGE_DIR}/usr/share/shim/BOOTX64.EFI" \
    "${STAGE_DIR}/boot/EFI/BOOT/BOOTX64.EFI"
copy_file "${STAGE_DIR}/usr/share/shim/mmx64.efi" \
    "${STAGE_DIR}/boot/EFI/BOOT/mmx64.efi"
copy_file "${STAGE_DIR}/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" \
    "${STAGE_DIR}/boot/EFI/BOOT/grubx64.efi"
create_file "${STAGE_DIR}/boot/loader/loader.conf" "timeout 5"

if [[ -v SECUREBOOT_CERT ]]; then
    openssl x509 -inform "PEM" -outform "DER" \
        -out "${STAGE_DIR}/boot/ENROLL_THIS_KEY.cer" <<< "${SECUREBOOT_CERT}"
fi

esp_size_mb=$(du --summarize --block-size="1M" "${STAGE_DIR}/boot" | \
    awk '{size = $1 + 32; print (size < 64 ? 64 : size)}')
force_remove "${ESP_IMG}"
truncate --size="${esp_size_mb}M" "${ESP_IMG}"
mkfs.fat -F 32 -n "EFIBOOT" "${ESP_IMG}"

_active_esp_mounts=()
create_directory "${ESP_MOUNT_DIR}"
managed_mount "_active_esp_mounts" "${ESP_IMG}" "${ESP_MOUNT_DIR}"
recursive_copy "${STAGE_DIR}/boot/." "${ESP_MOUNT_DIR}"
managed_unmount_all "_active_esp_mounts"
force_remove "${ESP_MOUNT_DIR}"

# === SquashFS & Hybrid ISO Generation ===

create_directory "${ISO_DIR}/LiveOS"

log_info "Creating SquashFS root image"
mksquashfs "${STAGE_DIR}" "${ISO_DIR}/LiveOS/squashfs.img" \
    -comp "zstd" -Xcompression-level "19" -b "1M" -noappend \
    -wildcards \
    -e "boot/*" \
    -e "etc/kernel" \
    -e "etc/resolv.conf" \
    -e "root/*" \
    -e "tmp/*" \
    -e "usr/src/*" \
    -e "var/cache/*" \
    -e "var/log/*" \
    -e "var/tmp/*"

IFS=" " read -r _ repo_profile < <(parse_profile "${PROFILE}")
iso_file="${BUILD_DIR}/installcd-${repo_profile//\//-}.iso"
force_remove "${iso_file}"

log_info "Building hybrid UEFI ISO ${iso_file}"
xorriso -as "mkisofs" \
    -iso-level "3" \
    -V "${ISO_VOLID}" \
    -partition_offset "16" \
    -append_partition "2" "0xef" "${ESP_IMG}" \
    -e "--interval:appended_partition_2:all::" \
    -no-emul-boot \
    -o "${iso_file}" \
    "${ISO_DIR}"

force_remove "${ESP_IMG}"
force_remove "${ISO_DIR}"
force_remove "${STAGE_DIR}"
log_info "ISO image created at ${iso_file}"
