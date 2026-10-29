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
cli_define_option "PACKAGES" "-P|--packages" \
    "Space-separated package atoms" 1
cli_define_option "USEPKG_EXCLUDE" "-e|--exclude" \
    "Binary packages to exclude" 0 ""
cli_define_flag "CLEAN_BINPKGS" "-c|--clean" \
    "Prune obsolete binary packages not installed" 0
cli_define_option "TIMEOUT" "-t|--timeout" \
    "Timeout duration for emerge (e.g. 330m)" 0 ""
cli_define_option "RESUME_ID" "-r|--resume-id" \
    "Unique snapshot identifier for resumption" 0 ""
cli_define_flag "RESUME" "-R|--resume" \
    "Resume build from intermediate snapshot" 0
cli_define_flag "JOBS" "-j|--jobs" \
    "Enable parallel emerge jobs using nproc (defaults to 1)" 0

cli_parse "${@}"
readonly PROFILE PACKAGES USEPKG_EXCLUDE CLEAN_BINPKGS \
    TIMEOUT RESUME_ID RESUME JOBS

emerge_jobs=1
if (( JOBS == 1 )); then
    emerge_jobs="$(nproc)"
fi
readonly emerge_jobs

check_root
check_required_commands

readonly STAGE_DIR="${BUILD_DIR}/stage"

# === Environment Preparation ===

prepare_stage_environment "${STAGE_DIR}" "${PROFILE}" \
    "${RESUME}" "${RESUME_ID}"

# === Build Packages ===

# Emerge requested packages. Rebuild reverse dependencies from source
# (--usepkg=n) to fix broken linkage before cleaning unused dependencies.
# When --clean is requested, prune binary packages not matching installed
# versions and refresh the binhost index.
build_exit=0
CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${STAGE_DIR}" '
    MAKEOPTS="--jobs=$(nproc)" emerge --jobs='"${emerge_jobs}"' \
        --usepkg-exclude="'"${USEPKG_EXCLUDE}"'" \
        app-portage/gentoolkit '"${PACKAGES}"'
    MAKEOPTS="--jobs=$(nproc)" revdep-rebuild.sh -- \
        --jobs='"${emerge_jobs}"' --usepkg=n
    emerge --depclean
    if (( '"${CLEAN_BINPKGS}"' == 1 )); then
        eclean-pkg --deep
        emaint --fix binhost
    fi
    ' || build_exit="${?}"

# === Cleanup & Upload ===

if (( build_exit == 124 )); then
    handle_build_timeout "${STAGE_DIR}" "${PROFILE}" \
        "${TIMEOUT}" "${RESUME_ID}"
elif (( build_exit != 0 )); then
    handle_build_failure "${STAGE_DIR}" "${PROFILE}" \
        "${RESUME_ID}" "${build_exit}"
fi

finish_stage_build "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}" ""
