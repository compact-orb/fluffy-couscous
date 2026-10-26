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

cli_define_option "SEED_ARCH" "-a|--arch" "Stage seed architecture" 1
cli_define_option "SEED_NAME" "-n|--name" "Stage seed tarball name" 1
cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_flag "WORKAROUND" "-w|--workaround" \
    "Apply bootstrap workaround instead of full rebuild"

cli_parse "${@}"
readonly SEED_ARCH SEED_NAME PROFILE WORKAROUND

check_root
check_required_commands

readonly SEED_DIR="${BUILD_DIR}/seed"
readonly STAGE_DIR="${BUILD_DIR}/stage"
readonly SEED_STAGE_BIND_DIR="${SEED_DIR}/tmp/stage"

# === Seed Environment Preparation ===

fetch_seed_stage "${SEED_DIR}" \
    "${SEED_ARCH}" "${SEED_NAME}"

configure_ebuild_repositories "${SEED_DIR}"
mount_repos "${SEED_DIR}"

if (( WORKAROUND )); then
    source "${WORK_DIR}/lib/workaround.sh"
else
    remove_portage_configuration "${SEED_DIR}"
    configure_portage "${SEED_DIR}" "${PROFILE}" "stage1"

    chroot_run "${SEED_DIR}" \
        'emerge --deep --getbinpkg --jobs="$(nproc)" --newuse --update @world'
fi

# === Bootstrapping Stage ===

create_directory "${STAGE_DIR}"
create_directory "${SEED_STAGE_BIND_DIR}"
_active_bootstrap_mounts=()
# Bind-mount STAGE_DIR to /tmp/stage in SEED_DIR so emerge --root=/tmp/stage
# writes stage1 bootstrap packages directly into the new target root.
managed_mount "_active_bootstrap_mounts" --bind "${STAGE_DIR}" \
    "${SEED_STAGE_BIND_DIR}"

# Install baselayout with USE=build first to create the root filesystem
# skeleton in /tmp/stage before emerging stage1 toolchain packages.
chroot_run "${SEED_DIR}" '
    USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
        sys-apps/baselayout
    '

# Resolve the stacked profile packages.build list via build.py and install the
# stage1 bootstrap toolchain into /tmp/stage without pulling implicit @system.
copy_file "${WORK_DIR}/bin/build.py" "${SEED_DIR}/tmp/build.py"
chroot_run "${SEED_DIR}" '
    buildpkgs=$(/tmp/build.py)
    emerge --implicit-system-deps=n --jobs="$(nproc)" --oneshot \
        --root="/tmp/stage" ${buildpkgs}
    locale-gen --prefix "/tmp/stage"
    '

# === Finalizing Stage 3 ===

managed_unmount_all "_active_bootstrap_mounts"

unmount_repos

force_remove "${SEED_DIR}"

create_directory "${STAGE_DIR}/etc/portage"

configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"

mount_repos "${STAGE_DIR}"

install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"

# Rebuild the entire @system set inside the new root using the stage1 toolchain
# so all base packages and generated binary packages match the target profile.
chroot_run "${STAGE_DIR}" '
    emerge --emptytree --jobs="$(nproc)" @system
    emerge --depclean
    '

unmount_repos

remove_portage_configuration "${STAGE_DIR}"

# === Artifact Upload ===

upload_binary_packages "${STAGE_DIR}" "${PROFILE}"
publish_stage_archive "${STAGE_DIR}" "${PROFILE}" "stage3"

force_remove "${STAGE_DIR}"
