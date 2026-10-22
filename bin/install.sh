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

if [[ "${_INSTALL_UNSHARED:-0}" != "1" ]]; then
    exec unshare --mount --propagation private env _INSTALL_UNSHARED=1 "$0" "${@}"
fi

# === CLI Arguments & Setup ===

required_commands=(
    "blkid"
    "btrfs"
    "dirname"
    "emerge"
    "getuto"
    "locale-gen"
    "mkfs.btrfs"
    "mkfs.fat"
    "python3"
    "realpath"
    "sfdisk"
    "shred"
    "udevadm"
    "unshare"
    "wipefs"
)


readonly ENCRYPT="${4:-false}"

if [[ "${ENCRYPT}" == "true" ]]; then
    required_commands+=(
        "base32"
        "cryptsetup"
        "systemd-cryptenroll"
    )
fi

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

check_required_commands

readonly PROFILE="${1}"
readonly INSTALL_DRIVE="${2}"
readonly SWAP_SIZE_GIB="${3}"
readonly INSTALL_MOUNT_DIR="${BUILD_DIR}/install"

readonly BOOT_MOUNT_OPTIONS="defaults,noatime,nodev,nosuid"
readonly ROOT_MOUNT_OPTIONS="defaults,noatime,compress-force=zstd:3,discard=async"
readonly HOME_MOUNT_OPTIONS="defaults,noatime,compress-force=zstd:3,discard=async,nodev,nosuid"
readonly VAR_LOG_MOUNT_OPTIONS="defaults,noatime,compress-force=zstd:3,discard=async,nodev,nosuid,noexec"
readonly VAR_TMP_MOUNT_OPTIONS="defaults,noatime,compress-force=zstd:3,discard=async,nodev,nosuid"
readonly SWAP_MOUNT_OPTIONS="defaults,noatime,nodev,nosuid,noexec"

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

    log_info "================================================================"
    log_info "EMERGENCY RECOVERY KEY: ${RECOVERY_KEY}"
    log_info "Please write this down and store it in a secure location!"
    log_info "================================================================"

    log_info "Enrolling TPM2 device with PIN (PCR 7)..."
    systemd-cryptenroll \
        --tpm2-device="auto" \
        --tpm2-pcrs="7" \
        --tpm2-with-pin="yes" \
        --unlock-key-file="${luks_key_file}" \
        "${ROOT_PARTITION}"

    managed_cryptsetup open \
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
btrfs subvolume create "${btrfs_tmp_dir}/@home"
btrfs subvolume create "${btrfs_tmp_dir}/@var_log"
btrfs subvolume create "${btrfs_tmp_dir}/@var_tmp"
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

create_directory "${INSTALL_MOUNT_DIR}/home"
managed_mount "_active_install_mounts" \
    --options "${HOME_MOUNT_OPTIONS},subvol=@home" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/home"

create_directory "${INSTALL_MOUNT_DIR}/var/log"
managed_mount "_active_install_mounts" \
    --options "${VAR_LOG_MOUNT_OPTIONS},subvol=@var_log" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/var/log"

create_directory "${INSTALL_MOUNT_DIR}/var/tmp"
managed_mount "_active_install_mounts" \
    --options "${VAR_TMP_MOUNT_OPTIONS},subvol=@var_tmp" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/var/tmp"
chmod 1777 "${INSTALL_MOUNT_DIR}/var/tmp"

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

managed_mount "_active_install_mounts" --bind \
    "${INSTALL_MOUNT_DIR}/var/tmp" "/var/tmp"

create_directory "${INSTALL_MOUNT_DIR}/var/cache"
chmod 0755 "${INSTALL_MOUNT_DIR}/var/cache"
managed_mount "_active_install_mounts" --bind \
    "${INSTALL_MOUNT_DIR}/var/cache" "/var/cache"

# === Configure Host Environment ===

download_ebuild_repositories

configure_ebuild_repositories ""

mount_repos ""

remove_portage_configuration ""
configure_portage "" "${PROFILE}" "install"

configure_portage_binary_packages "" "${PROFILE}"

# === Install Stage 1 ===

create_directory "${INSTALL_MOUNT_DIR}/usr/bin"
create_directory "${INSTALL_MOUNT_DIR}/usr/lib"
create_directory "${INSTALL_MOUNT_DIR}/usr/lib64"

create_symbolic_link "usr/bin" "${INSTALL_MOUNT_DIR}/bin"
create_symbolic_link "usr/bin" "${INSTALL_MOUNT_DIR}/sbin"
create_symbolic_link "bin" "${INSTALL_MOUNT_DIR}/usr/sbin"
create_symbolic_link "usr/lib" "${INSTALL_MOUNT_DIR}/lib"
create_symbolic_link "usr/lib64" "${INSTALL_MOUNT_DIR}/lib64"

USE="build" emerge --nodeps --oneshot --root="${INSTALL_MOUNT_DIR}" \
    sys-apps/baselayout

IFS=" " read -r -a buildpkgs <<< "$("${WORK_DIR}/bin/build.py")"
emerge --implicit-system-deps="n" --jobs="$(nproc)" --oneshot \
    --root="${INSTALL_MOUNT_DIR}" "${buildpkgs[@]}"
unset buildpkgs
locale-gen --prefix "${INSTALL_MOUNT_DIR}"

# === Clean Up Host Environment ===

unmount_repos

remove_portage_configuration ""

# === Install and Configure Gentoo ===

configure_portage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "install"

mount_repos "${INSTALL_MOUNT_DIR}"

configure_ebuild_repositories "${INSTALL_MOUNT_DIR}"

configure_portage_binary_packages "${INSTALL_MOUNT_DIR}" "${PROFILE}"

create_directory "${INSTALL_MOUNT_DIR}/etc/kernel"
create_file "${INSTALL_MOUNT_DIR}/etc/kernel/cmdline" \
    "resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET} rw console=tty0 console=ttyS0,115200"

extra_packages=(
    "app-admin/ansible"
    "app-admin/sudo"
    "app-crypt/tpm2-tools"
    "app-editors/nano"
    "dev-vcs/git"
    "net-misc/networkmanager"
    "sys-boot/shim"
    "sys-firmware/intel-microcode"
    "sys-firmware/sof-firmware"
    "sys-fs/btrfs-progs"
    "sys-fs/dosfstools"
    "sys-kernel/gentoo-kernel"
    "sys-kernel/installkernel"
    "sys-kernel/linux-firmware"
)

chroot_run "${INSTALL_MOUNT_DIR}" "
    emerge --emptytree --jobs=\"\$(nproc)\" @system ${extra_packages[*]}
    emerge --depclean
    "

# NOTE: The following systemd service enablement and bootloader configuration is
# interim and will be superseded by the Ansible configuration management project.

create_directory "${INSTALL_MOUNT_DIR}/usr/local/sbin"
create_file "${INSTALL_MOUNT_DIR}/usr/local/sbin/update-bootloader" \
'#!/usr/bin/env bash
set -euo pipefail

esp_boot_dir="/boot/EFI/BOOT"
mkdir --parents "${esp_boot_dir}"

if [[ -f "/usr/share/shim/BOOTX64.EFI" ]]; then
    cp -f "/usr/share/shim/BOOTX64.EFI" "${esp_boot_dir}/BOOTX64.EFI"
fi

if [[ -f "/usr/share/shim/mmx64.efi" ]]; then
    cp -f "/usr/share/shim/mmx64.efi" "${esp_boot_dir}/mmx64.efi"
fi

if [[ -f "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" ]]; then
    cp -f "/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed" "${esp_boot_dir}/grubx64.efi"
elif [[ -f "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" ]]; then
    cp -f "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" "${esp_boot_dir}/grubx64.efi"
fi
'
chmod "0755" "${INSTALL_MOUNT_DIR}/usr/local/sbin/update-bootloader"

create_directory "${INSTALL_MOUNT_DIR}/etc/systemd/system"
create_file "${INSTALL_MOUNT_DIR}/etc/systemd/system/update-bootloader.path" \
'[Unit]
Description=Watch for Shim and systemd-boot upgrades

[Path]
PathModified=/usr/share/shim/BOOTX64.EFI
PathModified=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
PathModified=/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
Unit=update-bootloader.service

[Install]
WantedBy=multi-user.target
'

create_file "${INSTALL_MOUNT_DIR}/etc/systemd/system/update-bootloader.service" \
'[Unit]
Description=Update ESP bootloader binaries (Shim + systemd-boot)
ConditionPathExists=/boot/EFI/BOOT

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-bootloader
'

chroot_run "${INSTALL_MOUNT_DIR}" '
    passwd --delete "root"
    systemctl preset-all
    systemctl enable NetworkManager.service
    bootctl --no-variables install
    systemctl mask systemd-boot-update.service
    systemctl enable update-bootloader.path
    /usr/local/sbin/update-bootloader
    '
create_file "${INSTALL_MOUNT_DIR}/etc/machine-id" "uninitialized"

create_symbolic_link "/run/systemd/resolve/stub-resolv.conf" \
    "${INSTALL_MOUNT_DIR}/etc/resolv.conf"

log_info "Generating fstab for ${INSTALL_MOUNT_DIR}"
fstab_file="${INSTALL_MOUNT_DIR}/etc/fstab"
log_debug "Creating ${fstab_file}"
declare fstab_content
IFS= read -d "" -r fstab_content << EOF || true
UUID=${ROOT_UUID} / btrfs ${ROOT_MOUNT_OPTIONS},subvol=@ 0 0
UUID=${BOOT_UUID} /boot vfat ${BOOT_MOUNT_OPTIONS} 0 2
UUID=${ROOT_UUID} /home btrfs ${HOME_MOUNT_OPTIONS},subvol=@home 0 0
UUID=${ROOT_UUID} /var/log btrfs ${VAR_LOG_MOUNT_OPTIONS},subvol=@var_log 0 0
UUID=${ROOT_UUID} /var/tmp btrfs ${VAR_TMP_MOUNT_OPTIONS},subvol=@var_tmp 0 0
UUID=${ROOT_UUID} /swap btrfs ${SWAP_MOUNT_OPTIONS},subvol=@swap 0 0
/swap/swapfile none swap defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,nodev,nosuid,noexec,mode=1777 0 0
tmpfs /dev/shm tmpfs defaults,noatime,nodev,nosuid,noexec 0 0
EOF
printf "%s" "${fstab_content}" > "${fstab_file}"
unset fstab_content fstab_file

remove_portage_configuration "${INSTALL_MOUNT_DIR}"

# TODO: Configure final binary packages thing. Probably should be Ansible's job.

# TEMPORARY: while Ansible is not yet ready
configure_portage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "install"
configure_portage_binary_packages "${INSTALL_MOUNT_DIR}" "${PROFILE}"

# === Clean Up ===

unmount_repos

managed_unmount_all "_active_install_mounts"

managed_cryptsetup close "root"
