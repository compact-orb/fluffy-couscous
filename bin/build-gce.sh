#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "blkid"
    "date"
    "dirname"
    "env"
    "mkfs.btrfs"
    "mkfs.fat"
    "partx"
    "realpath"
    "sfdisk"
    "tar"
    "truncate"
    "udevadm"
    "unshare"
)

source "$(realpath \
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh")"
source "$(realpath \
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/build.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1

cli_parse "${@}"
readonly PROFILE

check_root
check_required_commands

if [[ -z "${IMAGE_USER:-}" || -z "${IMAGE_SSH_PUBLIC_KEY:-}" ]]; then
    log_error "IMAGE_USER and IMAGE_SSH_PUBLIC_KEY must both be set"
    exit 1
fi

# Re-execute in a private mount namespace so image creation mounts (binds,
# chroot filesystems, tmpfs) remain isolated from the build runner host.
if [[ "${_GCE_UNSHARED:-0}" != "1" ]]; then
    exec unshare --mount --propagation private \
        env _GCE_UNSHARED=1 "$0" "${@}"
fi

readonly DISK_SIZE_GIB=10
readonly SWAP_SIZE_GIB=1
readonly GCE_DIR="${BUILD_DIR}/gce"
readonly RAW_DIR="${GCE_DIR}/raw"
readonly RAW_IMAGE="${RAW_DIR}/disk.raw"
readonly TARGET_ROOT="${BUILD_DIR}/target"

# === Prepare Raw Disk Image ===

log_info "Creating ${DISK_SIZE_GIB}GiB sparse raw disk image at ${RAW_IMAGE}"
create_directory "${RAW_DIR}"
truncate --size "${DISK_SIZE_GIB}G" "${RAW_IMAGE}"

managed_losetup attach "${RAW_IMAGE}" loop_dev

# Partition disk with GPT: 1GiB ESP (type=U) and Linux root (x86-64).
# Conforms to systemd Discoverable Partitions Specification (DPS).
sfdisk "${loop_dev}" <<EOF
label: gpt
size=1GiB, type=U
size=+, type="Linux root (x86-64)"
EOF

partx --update "${loop_dev}" 2> /dev/null || true
udevadm settle

readonly BOOT_PARTITION="${loop_dev}p1"
readonly ROOT_PARTITION="${loop_dev}p2"

mkfs.fat -F 32 "${BOOT_PARTITION}"
mkfs.btrfs --force "${ROOT_PARTITION}"

udevadm settle

readonly BOOT_UUID="$(blkid --match-tag "UUID" --output "value" \
    "${BOOT_PARTITION}")"
readonly ROOT_UUID="$(blkid --match-tag "UUID" --output "value" \
    "${ROOT_PARTITION}")"

prepare_target_subvolumes "${ROOT_PARTITION}"

_active_gce_mounts=()
mount_target_subvolumes "_active_gce_mounts" "${ROOT_PARTITION}" \
    "${BOOT_PARTITION}" "${TARGET_ROOT}" "${SWAP_SIZE_GIB}"

# === Install and Configure Gentoo ===

fetch_project_stage "${TARGET_ROOT}" "${PROFILE}" "stage3"

configure_portage "${TARGET_ROOT}" "${PROFILE}" "install"

mount_repos "${TARGET_ROOT}"

mount_binary_packages "${TARGET_ROOT}" "${PROFILE}"

create_directory "${TARGET_ROOT}/etc/kernel"
create_file "${TARGET_ROOT}/etc/kernel/cmdline" \
    "rw console=ttyS0,38400n8d console=tty0 lsm=landlock,yama,apparmor,bpf"

install_packages=(
    "app-admin/ansible"
    "app-admin/sudo"
    "app-crypt/tpm2-tools"
    "app-editors/nano"
    "dev-vcs/git"
    "net-misc/networkmanager"
    "sec-policy/apparmor-d"
    "sys-firmware/intel-microcode"
    "sys-fs/btrfs-progs"
    "sys-fs/dosfstools"
    "sys-kernel/gentoo-kernel"
    "sys-kernel/installkernel"
    "sys-kernel/linux-firmware"
    "sys-process/audit"
)

IFS=" "
chroot_run "${TARGET_ROOT}" '
    emerge --deep --jobs="$(nproc)" --newuse --update @world \
        '"${install_packages[*]}"'
    emerge --depclean
    '
IFS=$'\n\t'

generate_target_fstab "${TARGET_ROOT}" "${ROOT_UUID}" "${BOOT_UUID}"

install_secureboot_cert "${TARGET_ROOT}"

finalize_target_portage "${TARGET_ROOT}" "${PROFILE}"

unmount_binary_packages

# === Systemd, Bootloader, and Provisioning ===

export IMAGE_USER IMAGE_SSH_PUBLIC_KEY
chroot_run "${TARGET_ROOT}" '
    systemctl preset-all
    bootctl --no-variables install
    ansible-pull --url="'"${ANSIBLE_PULL_URL}"'"
    passwd --lock "root"
    useradd --create-home --groups wheel --shell /bin/bash \
        --user-group "${IMAGE_USER}"
    IFS=: read -r _ _ _ _ _ home_dir _ <<< "$(getent passwd "${IMAGE_USER}")"
    mkdir --parents "${home_dir}/.ssh"
    chmod 0700 "${home_dir}/.ssh"
    printf "%s\n" "${IMAGE_SSH_PUBLIC_KEY}" \
        > "${home_dir}/.ssh/authorized_keys"
    chmod 0600 "${home_dir}/.ssh/authorized_keys"
    chown --recursive "${IMAGE_USER}:${IMAGE_USER}" "${home_dir}/.ssh"
    '
unset IMAGE_USER IMAGE_SSH_PUBLIC_KEY

# Reset instance-specific state to produce a generic reusable base image
log_info "Resetting instance-specific identifiers for generic image"
create_empty_file "${TARGET_ROOT}/etc/machine-id"
force_remove "${TARGET_ROOT}/var/lib/dbus/machine-id"
force_remove "${TARGET_ROOT}/etc/hostname"
force_remove "${TARGET_ROOT}/root/.ansible"
for path in "${TARGET_ROOT}"/etc/ssh/ssh_host_*; do
    if [[ -e "${path}" || -L "${path}" ]]; then
        force_remove "${path}"
    fi
done

# === Unmount and Package Image Archive ===

managed_unmount_all "_active_gce_mounts"
managed_losetup detach "${loop_dev}"

IFS=" " read -r _ repo_profile < <(parse_profile "${PROFILE}")
profile_name="${repo_profile//\//-}"
date_tag="$(date --utc +"%Y%m%d")"
image_filename="gce-${profile_name}-${date_tag}.tar.gz"
archive_dir="${GCE_DIR}/archive"
create_directory "${archive_dir}"
image_file="${archive_dir}/${image_filename}"

log_info "Compressing raw disk image into ${image_file} (GNU oldgnu format)"
tar --create --directory="${RAW_DIR}" --file="${image_file}" \
    --format=oldgnu --gzip --sparse "disk.raw"

image_sig_file="${image_file}.sig"
sign_file "${image_file}" "${image_sig_file}"

upload_to_storageto "${image_file}"
upload_to_storageto "${image_sig_file}"

force_remove "${image_file}"
force_remove "${image_sig_file}"
force_remove "${RAW_IMAGE}"
force_remove "${TARGET_ROOT}"
force_remove "${GCE_DIR}"

log_info "Google Cloud image build completed successfully."
