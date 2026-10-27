#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "dirname"
    "realpath"
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/build.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_option "TIMEOUT" "-t|--timeout" \
    "Timeout duration for emerge (e.g. 330m)" 0 "0"
cli_define_option "RESUME_ID" "-r|--resume-id" \
    "Unique snapshot identifier for resumption" 0 ""
cli_define_flag "RESUME" "-R|--resume" \
    "Resume build from intermediate snapshot" 0

cli_parse "${@}"
readonly PROFILE TIMEOUT RESUME_ID RESUME

check_root
check_required_commands
readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

if (( RESUME == 1 )); then
    if [[ -z "${RESUME_ID}" ]]; then
        log_error "Resume requested but no resume ID provided"
        exit 1
    fi
    if ! has_resume_stage "${PROFILE}" "${RESUME_ID}"; then
        log_error "Resume snapshot for ${PROFILE} (${RESUME_ID}) not found"
        exit 1
    fi
    fetch_resume_stage "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}"
else
    # Fetch the existing base stage3 tarball from S3 and verify GPG signature.
    fetch_project_stage "${STAGE_DIR}" "${PROFILE}" "stage3"
fi

# Configure Portage settings (USE flags, make.conf, masks) for stage3 build.
configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

# Bind-mount synced ebuild repositories into the stage chroot.
mount_repos "${STAGE_DIR}"

# Install package signing and Secure Boot keys inside chroot for binpkg build.
install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"

# Mount S3 binhost via rclone and layer a writable OverlayFS on binpkgs dir.
mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

# === System Update ===

# Update @system with new USE flags and deep dependency tree. Rebuild packages
# with preserved libraries (@preserved-rebuild) across library soname bumps
# before final depclean.
build_exit=0
if (( RESUME == 1 )); then
    CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${STAGE_DIR}" '
        emerge --resume --jobs="$(nproc)"
        emerge --depclean
        emerge --jobs="$(nproc)" @preserved-rebuild
        emerge --depclean
        ' || build_exit="${?}"
else
    CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${STAGE_DIR}" '
        emerge --deep --jobs="$(nproc)" --newuse --update @system
        emerge --depclean
        emerge --jobs="$(nproc)" @preserved-rebuild
        emerge --depclean
        ' || build_exit="${?}"
fi

# === Cleanup & Upload ===

if (( build_exit == 124 )); then
    log_warn "Update timed out after ${TIMEOUT}"
    # Sync newly built/updated binary packages back to S3.
    upload_mounted_binary_packages "${STAGE_DIR}" "${PROFILE}"
    unmount_binary_packages
    if [[ -n "${RESUME_ID}" ]]; then
        publish_resume_stage "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}"
    fi
    unmount_repos
    remove_portage_configuration "${STAGE_DIR}"
    force_remove "${STAGE_DIR}"
    exit 124
elif (( build_exit != 0 )); then
    exit "${build_exit}"
fi

unmount_repos

remove_portage_configuration "${STAGE_DIR}"

# Sync newly built/updated binary packages back to S3.
upload_mounted_binary_packages "${STAGE_DIR}" "${PROFILE}"
unmount_binary_packages

# Publish the updated stage3 archive to S3 since updating @system advances the
# baseline root filesystem for this profile.
publish_stage_archive "${STAGE_DIR}" "${PROFILE}" "stage3"

if [[ -n "${RESUME_ID}" ]]; then
    clear_resume_stage "${PROFILE}" "${RESUME_ID}"
fi

force_remove "${STAGE_DIR}"
