#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "criu"
    "dirname"
    "mknod"
    "pivot_root"
    "realpath"
    "setsid"
    "tail"
    "unshare"
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/build.sh")"

cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_option "TIMEOUT" "-t|--timeout" \
    "Timeout duration for emerge (e.g. 330m)" 0 ""
cli_define_option "RESUME_ID" "-r|--resume-id" \
    "Unique snapshot identifier for resumption" 0 ""
cli_define_flag "RESUME" "-R|--resume" \
    "Resume build from intermediate snapshot" 0
cli_define_flag "JOBS" "-j|--jobs" \
    "Enable parallel emerge jobs using nproc (defaults to 1)" 0

cli_parse "${@}"
readonly PROFILE TIMEOUT RESUME_ID RESUME JOBS

emerge_jobs=1
if (( JOBS == 1 )); then
    emerge_jobs="$(nproc)"
fi
readonly emerge_jobs
cpus="$(nproc)"
make_jobs=$(( cpus > 1 ? cpus - 1 : 1 ))
readonly cpus make_jobs

check_root
check_required_commands
readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

prepare_stage_environment "${STAGE_DIR}" "${PROFILE}" \
    "${RESUME}" "${RESUME_ID}"

# === System Update ===

# Update @system with new USE flags and deep dependency tree. Rebuild packages
# with preserved libraries (@preserved-rebuild) across library soname bumps
# before final depclean.
build_exit=0
CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${STAGE_DIR}" '
    MAKEOPTS="--jobs='"${make_jobs}"' --load-average='"${make_jobs}"'" \
    emerge --jobs='"${emerge_jobs}"' --load-average='"${cpus}"' \
        --deep --newuse --update @system
    emerge --depclean
    MAKEOPTS="--jobs='"${make_jobs}"' --load-average='"${make_jobs}"'" \
    emerge --jobs='"${emerge_jobs}"' --load-average='"${cpus}"' \
        @preserved-rebuild
    emerge --depclean
    ' || build_exit="${?}"

# === Cleanup & Upload ===

if (( build_exit == 124 )); then
    handle_build_timeout "${STAGE_DIR}" "${PROFILE}" \
        "${TIMEOUT}" "${RESUME_ID}"
elif (( build_exit != 0 )); then
    handle_build_failure "${STAGE_DIR}" "${PROFILE}" \
        "${RESUME_ID}" "${build_exit}"
fi

finish_stage_build "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}" "stage3"
