#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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

# Inner realpath resolves the symlink (/usr/local/bin/install.sh ->
# /opt/fluffy-couscous/bin/install.sh) before dirname, so ../lib/ resolves
# relative to the real script location.
source "$(realpath \
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_option "INSTALL_DRIVE" "-d|--drive" "Target disk device" 1
cli_define_option "SWAP_SIZE_GIB" "-s|--swap" "Swap size in GiB" 1
cli_define_flag "ENCRYPT" "-e|--encrypt" "Enable LUKS encryption"

cli_parse "${@}"
readonly PROFILE INSTALL_DRIVE SWAP_SIZE_GIB ENCRYPT

check_root

if (( ENCRYPT )); then
    required_commands+=(
        "base32"
        "cryptsetup"
        "systemd-cryptenroll"
    )
fi

check_required_commands

# Required to avoid mounting relating issues
if [[ "${_INSTALL_UNSHARED:-0}" != "1" ]]; then
    exec unshare --mount --propagation private \
        env _INSTALL_UNSHARED=1 "$0" "${@}"
fi

readonly INSTALL_MOUNT_DIR="${BUILD_DIR}/install"

readonly BOOT_MOUNT_OPTIONS="defaults,noatime,nodev,nosuid"
readonly BTRFS_BASE_OPTS="defaults,noatime,compress-force=zstd:3,discard=async"
readonly ROOT_MOUNT_OPTIONS="${BTRFS_BASE_OPTS}"
readonly HOME_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid"
readonly VAR_LOG_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly VAR_TMP_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly PORTAGE_TMP_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid"
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

if (( ENCRYPT )); then
    readonly RECOVERY_KEY="$(head --bytes=20 /dev/urandom | base32 | \
        fold --width=5 | paste --delimiters='-' --serial -)"
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

readonly BOOT_UUID="$(blkid --match-tag "UUID" --output "value" \
    "${BOOT_PARTITION}")"
readonly ROOT_UUID="$(blkid --match-tag "UUID" --output "value" \
    "${ROOT_TARGET_DEV}")"
readonly ROOT_PARTUUID="$(blkid --match-tag "PARTUUID" --output "value" \
    "${ROOT_PARTITION}")"
if (( ENCRYPT )); then
    readonly LUKS_UUID="$(blkid --match-tag "UUID" --output "value" \
        "${ROOT_PARTITION}")"
fi

btrfs_tmp_dir="$(mktemp --directory)"
mount --types "btrfs" "${ROOT_TARGET_DEV}" "${btrfs_tmp_dir}"
btrfs subvolume create "${btrfs_tmp_dir}/@"
btrfs subvolume create "${btrfs_tmp_dir}/@home"
btrfs subvolume create "${btrfs_tmp_dir}/@var_log"
btrfs subvolume create "${btrfs_tmp_dir}/@var_tmp"
btrfs subvolume create "${btrfs_tmp_dir}/@var_tmp_portage"
btrfs subvolume create "${btrfs_tmp_dir}/@swap"

root_subvol_id="$(btrfs subvolume list "${btrfs_tmp_dir}" | awk \
    '$NF == "@" {print $2}')"
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

create_directory "${INSTALL_MOUNT_DIR}/var/tmp/portage"
managed_mount "_active_install_mounts" \
    --options "${PORTAGE_TMP_MOUNT_OPTIONS},subvol=@var_tmp_portage" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/var/tmp/portage"
chmod 0775 "${INSTALL_MOUNT_DIR}/var/tmp/portage"

create_directory "${INSTALL_MOUNT_DIR}/swap"
managed_mount "_active_install_mounts" \
    --options "${SWAP_MOUNT_OPTIONS},subvol=@swap" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/swap"

btrfs filesystem mkswapfile --size "${SWAP_SIZE_GIB}g" \
    "${INSTALL_MOUNT_DIR}/swap/swapfile"

readonly RESUME_OFFSET="$(btrfs inspect-internal map-swapfile --resume-offset \
    "${INSTALL_MOUNT_DIR}/swap/swapfile")"
log_info "Btrfs swapfile hibernation resume offset: ${RESUME_OFFSET}"

# Bind mount /var/tmp/portage and /var/cache to install drive to avoid
# issues with space
create_directory "/var/tmp/portage"
managed_mount "_active_install_mounts" --bind \
    "${INSTALL_MOUNT_DIR}/var/tmp/portage" "/var/tmp/portage"
create_directory "${INSTALL_MOUNT_DIR}/var/cache"
chmod 0755 "${INSTALL_MOUNT_DIR}/var/cache"
managed_mount "_active_install_mounts" --bind \
    "${INSTALL_MOUNT_DIR}/var/cache" "/var/cache"

# === Configure Host Environment ===

create_directory "/etc/portage"
managed_mount "_active_install_mounts" --types "tmpfs" "tmpfs" "/etc/portage"

configure_ebuild_repositories "/"

mount_repos "/"

configure_portage "/" "${PROFILE}" "install"

configure_portage_binary_packages "/" "${PROFILE}"

# === Install Stage 1 ===

# Needed when installing baselayout binary package with merge-usr
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
emerge --implicit-system-deps=n --jobs="$(nproc)" --oneshot \
    --root="${INSTALL_MOUNT_DIR}" "${buildpkgs[@]}"
unset buildpkgs
locale-gen --prefix "${INSTALL_MOUNT_DIR}"

# === Clean Up Host Environment ===

unmount_repos

remove_portage_configuration "/"

# === Install and Configure Gentoo ===

configure_portage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "install"

mount_repos "${INSTALL_MOUNT_DIR}"

configure_ebuild_repositories "${INSTALL_MOUNT_DIR}"

configure_portage_binary_packages "${INSTALL_MOUNT_DIR}" "${PROFILE}"

create_directory "${INSTALL_MOUNT_DIR}/etc/kernel"
declare cmdline
cmdline="root=UUID=${ROOT_UUID} rootflags=subvol=@"
if (( ENCRYPT )); then
    cmdline="rd.luks.uuid=${LUKS_UUID} ${cmdline}"
fi
cmdline+=" resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET}"
cmdline+=" rw console=tty0 console=ttyS0,115200"
create_file "${INSTALL_MOUNT_DIR}/etc/kernel/cmdline" "${cmdline}"
unset cmdline

install_packages=(
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

declare install_packages_str
printf -v install_packages_str "%s " "${install_packages[@]}"
chroot_run "${INSTALL_MOUNT_DIR}" '
    emerge --emptytree --jobs="$(nproc)" @system '"${install_packages_str}"'
    emerge --depclean
    '
unset install_packages_str

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
UUID=${ROOT_UUID} /var/tmp/portage btrfs ${PORTAGE_TMP_MOUNT_OPTIONS},subvol=@var_tmp_portage 0 0
UUID=${ROOT_UUID} /swap btrfs ${SWAP_MOUNT_OPTIONS},subvol=@swap 0 0
/swap/swapfile none swap defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,nodev,nosuid,noexec,mode=1777 0 0
tmpfs /dev/shm tmpfs defaults,noatime,nodev,nosuid,noexec 0 0
EOF
printf "%s" "${fstab_content}" > "${fstab_file}"
unset fstab_content fstab_file

# Clean up installer Portage configuration and establish profile symlink
remove_portage_configuration "${INSTALL_MOUNT_DIR}"
configure_portage_profile "${INSTALL_MOUNT_DIR}" "${PROFILE}"

unmount_repos

chroot_run "${INSTALL_MOUNT_DIR}" '
    passwd --delete "root"
    systemd-machine-id-setup
    systemctl preset-all
    bootctl --no-variables install
    ansible-pull --checkout="main" \
        --url="'"${ANSIBLE_PULL_URL}"'" \
        --inventory="localhost," \
        --limit="localhost"
    '

# === Clean Up ===

managed_unmount_all "_active_install_mounts"

managed_cryptsetup close "root"
