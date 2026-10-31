#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "blkid"
    "btrfs"
    "chattr"
    "chown"
    "dirname"
    "mkfs.btrfs"
    "mkfs.fat"
    "openssl"
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
cli_define_option "USERNAME" "-u|--user" "Standard user username" 0
cli_define_option "PASSWORD" "--password" "Standard user password" 0
cli_define_option "TPM2_PIN" "--pin" "TPM2 LUKS PIN" 0

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

# Re-execute in a private mount namespace so installation mounts (binds,
# chroot filesystems, tmpfs) remain isolated from the live host.
if [[ "${_INSTALL_UNSHARED:-0}" != "1" ]]; then
    exec unshare --mount --propagation private \
        env _INSTALL_UNSHARED=1 "$0" "${@}"
fi

if [[ -z "${USERNAME:-}" ]]; then
    while true; do
        read -r -p "Enter username for standard user: " USERNAME
        if [[ "${USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]] && \
            [[ "${USERNAME}" != "root" ]]; then
            break
        fi
        log_error "Invalid username. Must be lowercase alphanumeric, not root."
    done
fi

if [[ -z "${PASSWORD:-}" ]]; then
    while true; do
        read -r -s -p "Enter password for ${USERNAME}: " PASSWORD
        echo
        read -r -s -p "Confirm password: " password_confirm
        echo
        if [[ -n "${PASSWORD}" ]] && \
            [[ "${PASSWORD}" == "${password_confirm}" ]]; then
            unset password_confirm
            break
        fi
        log_error "Passwords do not match or are empty. Try again."
    done
fi

if (( ENCRYPT )) && [[ -z "${TPM2_PIN:-}" ]]; then
    while true; do
        read -r -s -p "Enter TPM2 PIN for LUKS: " TPM2_PIN
        echo
        read -r -s -p "Confirm TPM2 PIN: " tpm2_pin_confirm
        echo
        if [[ -n "${TPM2_PIN}" ]] && \
            [[ "${TPM2_PIN}" == "${tpm2_pin_confirm}" ]]; then
            unset tpm2_pin_confirm
            break
        fi
        log_error "TPM2 PINs do not match or are empty. Try again."
    done
fi

readonly INSTALL_MOUNT_DIR="${BUILD_DIR}/install"

readonly BOOT_MOUNT_OPTIONS="defaults,noatime,nodev,nosuid,umask=0077"
readonly BTRFS_BASE_OPTS="defaults,noatime,compress-force=zstd:3,discard=async"
readonly ROOT_MOUNT_OPTIONS="${BTRFS_BASE_OPTS}"
readonly HOME_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid"
readonly VAR_LOG_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly VAR_TMP_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly PORTAGE_TMP_MOUNT_OPTIONS="${BTRFS_BASE_OPTS},nodev,nosuid"
readonly VAR_CACHE_BINPKGS_MOUNT_OPTIONS=\
"${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly VAR_CACHE_BINHOST_MOUNT_OPTIONS=\
"${BTRFS_BASE_OPTS},nodev,nosuid,noexec"
readonly SWAP_MOUNT_OPTIONS="defaults,noatime,nodev,nosuid,noexec"

# === Prepare Drive ===

wipefs --all --force "${INSTALL_DRIVE}"

# Partition disk with GPT: 1GiB ESP (type=U) and Linux root (x86-64).
# Conforms to systemd Discoverable Partitions Specification (DPS) so systemd
# auto-discovers / and /boot without root= or rd.luks.uuid= in kernel cmdline.
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
    # Format root with LUKS2 using a 20-byte random base32 emergency key.
    # Pause execution so user has time to record the recovery key.
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
    echo
    read -r -p \
        "Press [Enter] once you have securely recorded this key..."
    echo

    # Enroll TPM2 PCR 7 (Secure Boot state) with user PIN so volume unlocks
    # automatically at boot only when the firmware boot chain is untampered.
    log_info "Enrolling TPM2 device with PIN (PCR 7)..."
    tpm2_creds_dir="$(mktemp --directory)"
    chmod 0700 "${tpm2_creds_dir}"
    printf "%s" "${TPM2_PIN}" > \
        "${tpm2_creds_dir}/cryptenroll.new-tpm2-pin"

    CREDENTIALS_DIRECTORY="${tpm2_creds_dir}" systemd-cryptenroll \
        --tpm2-device="auto" \
        --tpm2-pcrs="7" \
        --tpm2-with-pin="yes" \
        --unlock-key-file="${luks_key_file}" \
        "${ROOT_PARTITION}"

    shred --remove "${tpm2_creds_dir}/cryptenroll.new-tpm2-pin"
    remove_directory "${tpm2_creds_dir}"
    unset tpm2_creds_dir TPM2_PIN

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

btrfs_tmp_dir="$(mktemp --directory)"
mount --types "btrfs" "${ROOT_TARGET_DEV}" "${btrfs_tmp_dir}"
# Create subvolumes for system isolation. Mark binpkgs and binhost with +C
# (nodatacow) to avoid compression overhead on pre-compressed packages and
# isolate high-churn package caches from root snapshots.
btrfs subvolume create "${btrfs_tmp_dir}/@"
btrfs subvolume create "${btrfs_tmp_dir}/@home"
btrfs subvolume create "${btrfs_tmp_dir}/@var_log"
btrfs subvolume create "${btrfs_tmp_dir}/@var_tmp"
btrfs subvolume create "${btrfs_tmp_dir}/@var_tmp_portage"
btrfs subvolume create "${btrfs_tmp_dir}/@var_cache_binpkgs"
chattr +C "${btrfs_tmp_dir}/@var_cache_binpkgs"
btrfs subvolume create "${btrfs_tmp_dir}/@var_cache_binhost"
chattr +C "${btrfs_tmp_dir}/@var_cache_binhost"
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

create_directory "${INSTALL_MOUNT_DIR}/var/cache/binpkgs"
managed_mount "_active_install_mounts" \
    --options \
    "${VAR_CACHE_BINPKGS_MOUNT_OPTIONS},subvol=@var_cache_binpkgs" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/var/cache/binpkgs"
chmod 0755 "${INSTALL_MOUNT_DIR}/var/cache/binpkgs"

create_directory "${INSTALL_MOUNT_DIR}/var/cache/binhost"
managed_mount "_active_install_mounts" \
    --options \
    "${VAR_CACHE_BINHOST_MOUNT_OPTIONS},subvol=@var_cache_binhost" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/var/cache/binhost"
chmod 0755 "${INSTALL_MOUNT_DIR}/var/cache/binhost"

create_directory "${INSTALL_MOUNT_DIR}/swap"
managed_mount "_active_install_mounts" \
    --options "${SWAP_MOUNT_OPTIONS},subvol=@swap" \
    --types "btrfs" \
    "${ROOT_TARGET_DEV}" \
    "${INSTALL_MOUNT_DIR}/swap"

btrfs filesystem mkswapfile --size "${SWAP_SIZE_GIB}g" \
    "${INSTALL_MOUNT_DIR}/swap/swapfile"

# === Install and Configure Gentoo ===

fetch_project_stage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "stage3"

configure_portage "${INSTALL_MOUNT_DIR}" "${PROFILE}" "install"

mount_repos "${INSTALL_MOUNT_DIR}"

configure_portage_binary_packages "${INSTALL_MOUNT_DIR}" "${PROFILE}"

create_directory "${INSTALL_MOUNT_DIR}/etc/kernel"
create_file "${INSTALL_MOUNT_DIR}/etc/kernel/cmdline" \
    "rw console=tty0 console=ttyS0,115200 lsm=landlock,yama,apparmor,bpf"

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

IFS=" "
chroot_run "${INSTALL_MOUNT_DIR}" '
    emerge --deep --jobs="$(nproc)" --newuse --update @world \
        '"${install_packages[*]}"'
    emerge --depclean
    '
IFS=$'\n\t'

log_info "Generating fstab for ${INSTALL_MOUNT_DIR}"
fstab_file="${INSTALL_MOUNT_DIR}/etc/fstab"
log_debug "Creating ${fstab_file}"
portage_opts="${PORTAGE_TMP_MOUNT_OPTIONS},subvol=@var_tmp_portage"
binpkg_opts="${VAR_CACHE_BINPKGS_MOUNT_OPTIONS},subvol=@var_cache_binpkgs"
binhost_opts="${VAR_CACHE_BINHOST_MOUNT_OPTIONS},subvol=@var_cache_binhost"
declare fstab_content
IFS= read -d "" -r fstab_content << EOF || true
UUID=${ROOT_UUID} / btrfs ${ROOT_MOUNT_OPTIONS},subvol=@ 0 0
UUID=${BOOT_UUID} /boot vfat ${BOOT_MOUNT_OPTIONS} 0 2
UUID=${ROOT_UUID} /home btrfs ${HOME_MOUNT_OPTIONS},subvol=@home 0 0
UUID=${ROOT_UUID} /var/log btrfs ${VAR_LOG_MOUNT_OPTIONS},subvol=@var_log 0 0
UUID=${ROOT_UUID} /var/tmp btrfs ${VAR_TMP_MOUNT_OPTIONS},subvol=@var_tmp 0 0
UUID=${ROOT_UUID} /var/tmp/portage btrfs ${portage_opts} 0 0
UUID=${ROOT_UUID} /var/cache/binpkgs btrfs ${binpkg_opts} 0 0
UUID=${ROOT_UUID} /var/cache/binhost btrfs ${binhost_opts} 0 0
UUID=${ROOT_UUID} /swap btrfs ${SWAP_MOUNT_OPTIONS},subvol=@swap 0 0
/swap/swapfile none swap defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,nodev,nosuid,noexec,mode=1777 0 0
tmpfs /dev/shm tmpfs defaults,noatime,nodev,nosuid,noexec 0 0
EOF
printf "%s" "${fstab_content}" > "${fstab_file}"
unset fstab_content fstab_file portage_opts binpkg_opts binhost_opts

if [[ -n "${SECUREBOOT_CERT:-}" ]]; then
    log_info "Exporting Secure Boot certificate to ESP"
    openssl x509 -inform "PEM" -outform "DER" \
        -out "${INSTALL_MOUNT_DIR}/boot/Secure Boot Certificate.der" \
        <<< "${SECUREBOOT_CERT}"
elif [[ -f "/boot/Secure Boot Certificate.der" ]]; then
    log_info "Copying Secure Boot certificate to ESP"
    copy_file "/boot/Secure Boot Certificate.der" \
        "${INSTALL_MOUNT_DIR}/boot/Secure Boot Certificate.der"
fi

# Clean up installer Portage configuration and establish profile symlink
remove_portage_configuration "${INSTALL_MOUNT_DIR}"
configure_portage_profile "${INSTALL_MOUNT_DIR}" "${PROFILE}"

unmount_repos

for repo_entry in "${_repo_entries[@]}"; do
    repo_name="${repo_entry%% *}"
    log_info "Copying ${repo_name} repository to target"
    cp --archive "${LOCAL_REPOS_DIR}/${repo_name}/." \
        "${INSTALL_MOUNT_DIR}/var/db/repos/${repo_name}"
done
unset repo_entry repo_name

chown -R portage:portage "${INSTALL_MOUNT_DIR}/var/db/repos"

# Initialize machine-id, install systemd-boot to ESP (without writing NVRAM
# variables from inside chroot), run Ansible pull for post-install setup,
# lock root account, and create unprivileged admin user in wheel group.
chroot_run "${INSTALL_MOUNT_DIR}" '
    systemd-machine-id-setup
    systemctl preset-all
    bootctl --no-variables install
    ansible-pull --url="'"${ANSIBLE_PULL_URL}"'"
    passwd --lock "root"
    useradd --create-home --user-group --groups wheel \
        --shell /bin/bash "'"${USERNAME}"'"
    printf "%s\n" "'"${PASSWORD}"'" | passwd --stdin "'"${USERNAME}"'"
    '
unset USERNAME PASSWORD

# === Clean Up ===

managed_unmount_all "_active_install_mounts"

managed_cryptsetup close "root"

log_info "Installation finished successfully."
