#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/build.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1

cli_parse "${@}"
readonly PROFILE

check_root
check_required_commands
readonly STAGE_DIR="${BUILD_DIR}/stage"
readonly ESP_MOUNT_DIR="${BUILD_DIR}/esp"
readonly ESP_IMG="${BUILD_DIR}/esp.img"
readonly ISO_DIR="${BUILD_DIR}/iso"
readonly ISO_VOLID="INSTALL"
IFS=" " read -r _ repo_profile < <(parse_profile "${PROFILE}")
readonly ISO_DATE="$(date +%Y%m%d)"
readonly ISO_FILE=\
"${BUILD_DIR}/install-${repo_profile//\//-}-${ISO_DATE}.iso"
readonly ISO_SIG_FILE="${ISO_FILE}.sig"
unset repo_profile ISO_DATE

# === Environment Preparation ===

fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"

configure_portage "${STAGE_DIR}" "${PROFILE}" "install"

mount_repos "${STAGE_DIR}"

mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

create_directory "${STAGE_DIR}/boot/loader/entries"
create_empty_file "${STAGE_DIR}/etc/machine-id"

# Configure dracut for live booting with dmsquash-live module to mount the
# SquashFS root filesystem from CD/USB media.
create_directory "${STAGE_DIR}/etc/dracut.conf.d"
create_file "${STAGE_DIR}/etc/dracut.conf.d/install.conf" \
    'hostonly="no"
add_dracutmodules+=" dmsquash-live "'

# Configure live kernel command line: specify CDLABEL to locate live media,
# enable writable overlayfs, serial/tty console, and security LSM order.
create_directory "${STAGE_DIR}/etc/kernel"
cmdline="root=live:CDLABEL=${ISO_VOLID} rd.live.overlay.overlayfs=1"
cmdline="${cmdline} console=tty0 console=ttyS0,115200"
cmdline="${cmdline} lsm=landlock,yama,apparmor,bpf"
create_file "${STAGE_DIR}/etc/kernel/cmdline" "${cmdline}"

# === Build Install ===

# Install live environment packages. Delete root password to allow
# passwordless console login, enable NetworkManager, and record system state.
chroot_run "${STAGE_DIR}" '
    emerge --buildpkg=n --jobs="$(nproc)" --usepkgonly \
        app-admin/sudo app-arch/7zip app-crypt/tpm2-tools app-editors/nano \
        dev-vcs/git net-misc/networkmanager net-misc/rclone sys-boot/shim \
        sys-firmware/intel-microcode sys-firmware/sof-firmware \
        sys-fs/btrfs-progs sys-fs/dosfstools sys-fs/e2fsprogs sys-fs/xfsprogs \
        sys-kernel/gentoo-kernel sys-kernel/installkernel \
        sys-kernel/linux-firmware
    emerge --depclean
    passwd --delete "root"
    systemctl disable systemd-networkd.service \
        systemd-networkd-wait-online.service
    systemctl enable NetworkManager.service \
        NetworkManager-wait-online.service systemd-resolved.service
    /usr/lib/systemd/systemd-update-done
    '

# Point resolv.conf to systemd-resolved stub listener for DNS resolution.
force_remove "${STAGE_DIR}/etc/resolv.conf"
create_symbolic_link "/run/systemd/resolve/stub-resolv.conf" \
    "${STAGE_DIR}/etc/resolv.conf"

# === Chroot Cleanup ===

unmount_repos

remove_portage_configuration "${STAGE_DIR}"

unmount_binary_packages

# === EFI Partition Setup ===

log_info "Creating EFI Partition"

# Set up UEFI bootloader directory on ESP. Copy signed systemd-boot to
# grubx64.efi because standard Microsoft-signed Shim chainloads grubx64.efi.
create_directory "${STAGE_DIR}/boot/EFI/BOOT"

copy_file "${STAGE_DIR}/usr/share/shim/BOOTX64.EFI" \
    "${STAGE_DIR}/boot/EFI/BOOT/BOOTX64.EFI"
copy_file "${STAGE_DIR}/usr/share/shim/mmx64.efi" \
    "${STAGE_DIR}/boot/EFI/BOOT/mmx64.efi"
copy_file "${STAGE_DIR}/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" \
    "${STAGE_DIR}/boot/EFI/BOOT/grubx64.efi"

# systemd-boot loader entry paths are relative to the ESP root, not /boot.
sed --in-place 's| /boot/| /|g' "${STAGE_DIR}"/boot/loader/entries/*.conf

# Export Secure Boot certificate in DER format for MokManager key enrollment.
openssl x509 -inform "PEM" -outform "DER" \
     -out "${STAGE_DIR}/boot/Secure Boot Certificate.der" \
     <<< "${SECUREBOOT_CERT}"

# Calculate required ESP FAT32 size with 3% headroom, enforcing 35MB minimum.
esp_size_mb=$(du --summarize --block-size="1M" "${STAGE_DIR}/boot" | \
    awk '{
        size = int($1 * 1.03) + 2
        print (size < 35 ? 35 : size)
    }')
force_remove "${ESP_IMG}"
truncate --size="${esp_size_mb}M" "${ESP_IMG}"
mkfs.fat -F 32 "${ESP_IMG}"

_active_esp_mounts=()
create_directory "${ESP_MOUNT_DIR}"
managed_mount "_active_esp_mounts" "${ESP_IMG}" "${ESP_MOUNT_DIR}"
recursive_copy "${STAGE_DIR}/boot/." "${ESP_MOUNT_DIR}"
managed_unmount_all "_active_esp_mounts"
force_remove "${ESP_MOUNT_DIR}"

# === Bundle Installer into Image ===

log_info "Bundling installer into image"
readonly INSTALLER_TARGET_DIR="${STAGE_DIR}/opt/fluffy-couscous"
create_directory "${INSTALLER_TARGET_DIR}"
for dir in "bin" "lib" "keys" "portage"; do
    if [[ -d "${WORK_DIR}/${dir}" ]]; then
        create_directory "${INSTALLER_TARGET_DIR}/${dir}"
        recursive_copy "${WORK_DIR}/${dir}/." "${INSTALLER_TARGET_DIR}/${dir}"
    fi
done

# Create symlink so user can run install.sh directly from PATH
create_directory "${STAGE_DIR}/usr/local/bin"
create_symbolic_link "/opt/fluffy-couscous/bin/install.sh" \
    "${STAGE_DIR}/usr/local/bin/install.sh"

# Write sanitized .env containing only public repo, verification, and
# read-only S3 keys; write-capable secrets (SIGNING_KEY, SECUREBOOT_KEY,
# S3_SECRET_ACCESS_KEY) are strictly omitted.
IFS= read -d "" -r installer_env << EOF || true
GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL}"
REPOS="${REPOS}"
BINPKG_REPOS="${BINPKG_REPOS}"
ANSIBLE_PULL_URL="${ANSIBLE_PULL_URL}"
BINPKG_PUBLIC_KEY="${BINPKG_PUBLIC_KEY:-}"
REPO_PUBLIC_KEYS="${REPO_PUBLIC_KEYS:-}"
SECUREBOOT_CERT="${SECUREBOOT_CERT:-}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
S3_RO_SECRET_ACCESS_KEY="${S3_RO_SECRET_ACCESS_KEY:-}"
S3_REGION="${S3_REGION}"
S3_ENDPOINT="${S3_ENDPOINT}"
S3_BUCKET_NAME="${S3_BUCKET_NAME}"
EOF
printf "%s" "${installer_env}" > "${INSTALLER_TARGET_DIR}/.env"
unset installer_env
chmod 0644 "${INSTALLER_TARGET_DIR}/.env"

# === Build SquashFS Image ===

# Compress root filesystem into SquashFS image with zstd, excluding /boot
# (placed on the ESP image) and ephemeral files/caches.
log_info "Creating SquashFS image"
create_directory "${ISO_DIR}/LiveOS"
mksquashfs "${STAGE_DIR}" "${ISO_DIR}/LiveOS/squashfs.img" \
    -Xcompression-level "19" -b "1M" -comp "zstd" -noappend \
    -wildcards \
    -e "boot/*" \
    -e "etc/dracut.conf.d" \
    -e "etc/kernel" \
    -e "root/*" \
    -e "tmp/*" \
    -e "var/cache/*" \
    -e "var/lib/systemd/catalog/database" \
    -e "var/log/*" \
    -e "var/tmp/*"

# === Build ISO Image ===

# Generate hybrid UEFI bootable ISO with xorriso, embedding the ESP image as
# partition 2 (type 0xef) for native UEFI boot from CD/USB.
log_info "Building ISO image"
force_remove "${ISO_FILE}"
xorriso \
    -outdev "${ISO_FILE}" \
    -append_partition "2" "0xef" "${ESP_IMG}" \
    -boot_image "any" "efi_path=--interval:appended_partition_2:all::" \
    -boot_image "any" "emul_type=no_emulation" \
    -boot_image "any" "partition_offset=16" \
    -compliance "iso_9660_level=3" \
    -map "${ISO_DIR}" "/" \
    -volid "${ISO_VOLID}"

force_remove "${ESP_IMG}"
force_remove "${ISO_DIR}"
force_remove "${STAGE_DIR}"

# === Upload ISO Image and Signature ===

sign_file "${ISO_FILE}" "${ISO_SIG_FILE}"

upload_to_storageto "${ISO_FILE}"
upload_to_storageto "${ISO_SIG_FILE}"

force_remove "${ISO_FILE}"
force_remove "${ISO_SIG_FILE}"
