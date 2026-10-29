#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "criu"
    "dirname"
    "mknod"
    "mv"
    "pivot_root"
    "realpath"
    "setsid"
    "tail"
    "unshare"
)

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"
source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/build.sh")"

cli_define_option "SEED_ARCH" "-a|--arch" "Stage seed architecture" 0 ""
cli_define_option "SEED_NAME" "-n|--name" "Stage seed tarball name" 0 ""
cli_define_option "SEED_STAGE" "-s|--seed-stage" \
    "Custom stage3 profile to use as seed" 0 ""
cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_flag "WORKAROUND" "-w|--workaround" \
    "Apply bootstrap workaround instead of full rebuild"
cli_define_option "TIMEOUT" "-t|--timeout" \
    "Timeout duration for emerge (e.g. 330m)" 0 ""
cli_define_option "RESUME_ID" "-r|--resume-id" \
    "Unique snapshot identifier for resumption" 0 ""
cli_define_flag "RESUME" "-R|--resume" \
    "Resume build from intermediate snapshot" 0
cli_define_flag "JOBS" "-j|--jobs" \
    "Enable parallel emerge jobs using nproc (defaults to 1)" 0

cli_parse "${@}"
readonly SEED_ARCH SEED_NAME SEED_STAGE PROFILE WORKAROUND \
    TIMEOUT RESUME_ID RESUME JOBS

emerge_jobs=1
if (( JOBS == 1 )); then
    emerge_jobs="$(nproc)"
fi
readonly emerge_jobs

if [[ -n "${SEED_STAGE}" ]]; then
    if [[ -n "${SEED_ARCH}" || -n "${SEED_NAME}" ]]; then
        log_error "--seed-stage cannot be used with --arch or --name."
        exit 1
    fi
    if (( WORKAROUND )); then
        log_error "--workaround cannot be used with --seed-stage."
        exit 1
    fi
else
    if [[ -z "${SEED_ARCH}" || -z "${SEED_NAME}" ]]; then
        log_error "Must specify either --seed-stage" \
            "or both --arch and --name."
        exit 1
    fi
fi

check_root
check_required_commands

readonly SEED_DIR="${BUILD_DIR}/seed"
readonly STAGE_DIR="${BUILD_DIR}/stage"
readonly SEED_STAGE_BIND_DIR="${SEED_DIR}/tmp/stage"

# === Resumption Phase Determination ===

resume_phase=""
if (( RESUME == 1 )); then
    if [[ -z "${RESUME_ID}" ]]; then
        log_error "Resume requested but no resume ID provided"
        exit 1
    fi
    if has_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3"; then
        resume_phase="stage3"
    elif has_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3-init"; then
        resume_phase="stage3-init"
    elif has_resume_stage "${PROFILE}" "${RESUME_ID}" "stage1"; then
        resume_phase="stage1"
    else
        log_error "No resume snapshot found for ${PROFILE} (${RESUME_ID})"
        exit 1
    fi
fi

# === Phase 1 & 2: Stage 1 Bootstrapping ===

if [[ "${resume_phase}" != "stage3" && \
      "${resume_phase}" != "stage3-init" ]]; then
    stage1_exit=0

    if [[ "${resume_phase}" == "stage1" ]]; then
        fetch_resume_stage "${SEED_DIR}" "${PROFILE}" "${RESUME_ID}" "stage1"
        if [[ ! -d "${SEED_DIR}/.criu" ]]; then
            log_error "CRIU checkpoint not found in ${SEED_DIR}"
            exit 1
        fi
        download_ebuild_repositories "${SEED_DIR}"
        mount_repos "${SEED_DIR}"
        install_secureboot_keys "${SEED_DIR}"
    else
        # --- Seed Environment Preparation ---
        if [[ -n "${SEED_STAGE}" ]]; then
            fetch_project_stage "${SEED_DIR}" "${SEED_STAGE}" "stage3"
        else
            fetch_seed_stage "${SEED_DIR}" \
                "${SEED_ARCH}" "${SEED_NAME}"
        fi

        configure_ebuild_repositories "${SEED_DIR}"
        mount_repos "${SEED_DIR}"

        if (( WORKAROUND )); then
            source "${WORK_DIR}/lib/workaround.sh"
        else
            remove_portage_configuration "${SEED_DIR}"
            configure_portage "${SEED_DIR}" "${PROFILE}" "stage1"
            install_secureboot_keys "${SEED_DIR}"

            if [[ -z "${SEED_STAGE}" ]]; then
                chroot_run "${SEED_DIR}" '
                    cpus=$(nproc)
                    make_jobs=$(( cpus > 1 ? cpus - 1 : 1 ))
                    MAKEOPTS="--jobs=${make_jobs} --load-average=${make_jobs}" \
                        emerge --deep --getbinpkg \
                        --jobs='"${emerge_jobs}"' \
                        --load-average="${cpus}" \
                        --newuse --update @world
                    '
            fi
        fi

        # --- Toolchain Bootstrapping into /tmp/stage ---
        copy_file "${WORK_DIR}/bin/build.py" "${SEED_DIR}/tmp/build.py"
        create_directory "${SEED_STAGE_BIND_DIR}/etc/portage"

        chroot_run "${SEED_DIR}" '
            USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
                sys-apps/baselayout
            '
    fi

    CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${SEED_DIR}" '
        buildpkgs=$(/tmp/build.py)
        cpus=$(nproc)
        make_jobs=$(( cpus > 1 ? cpus - 1 : 1 ))
        MAKEOPTS="--jobs=${make_jobs} --load-average=${make_jobs}" \
        emerge --jobs='"${emerge_jobs}"' --load-average="${cpus}" \
            --implicit-system-deps=n --oneshot --root="/tmp/stage" \
            ${buildpkgs}
        locale-gen --prefix "/tmp/stage"
        ' || stage1_exit="${?}"

    # --- Stage 1 Timeout & Failure Handling ---
    if (( stage1_exit == 124 )); then
        log_warn "Stage 1 build timed out after ${TIMEOUT}"
        unmount_repos
        if [[ -n "${RESUME_ID}" ]]; then
            publish_resume_stage "${SEED_DIR}" "${PROFILE}" \
                "${RESUME_ID}" "stage1"
        fi
        force_remove "${SEED_DIR}"
        exit 124
    elif (( stage1_exit != 0 )); then
        if [[ -n "${RESUME_ID}" ]]; then
            clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage1"
        fi
        unmount_repos
        upload_portage_failure_logs "${stage1_exit}"
        force_remove "${SEED_DIR}"
        exit "${stage1_exit}"
    fi

    # --- Stage 1 Completion & Clean Handoff ---
    unmount_repos
    force_remove "${STAGE_DIR}"
    mv "${SEED_STAGE_BIND_DIR}" "${STAGE_DIR}"
    force_remove "${SEED_DIR}"
    force_remove "${STAGE_DIR}/var/cache/edb"

    if [[ -n "${RESUME_ID}" ]]; then
        log_info "Stage 1 complete. Publishing stage3-init and yielding."
        publish_resume_stage "${STAGE_DIR}" "${PROFILE}" \
            "${RESUME_ID}" "stage3-init"
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage1"
        force_remove "${STAGE_DIR}"
        exit 124
    fi
fi

# === Phase 3: Stage 3 Finalizing Rebuild ===

if [[ "${resume_phase}" == "stage3" ]]; then
    fetch_resume_stage "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}" "stage3"
    if [[ ! -d "${STAGE_DIR}/.criu" ]]; then
        log_error "CRIU checkpoint not found in ${STAGE_DIR}"
        exit 1
    fi
    download_ebuild_repositories "${STAGE_DIR}"
else
    if [[ "${resume_phase}" == "stage3-init" ]]; then
        fetch_resume_stage "${STAGE_DIR}" "${PROFILE}" \
            "${RESUME_ID}" "stage3-init"
    fi
    create_directory "${STAGE_DIR}/etc/portage"
    configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"
fi
mount_repos "${STAGE_DIR}"
install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"

stage3_exit=0
CHROOT_TIMEOUT="${TIMEOUT}" chroot_run "${STAGE_DIR}" '
    cpus=$(nproc)
    make_jobs=$(( cpus > 1 ? cpus - 1 : 1 ))
    MAKEOPTS="--jobs=${make_jobs} --load-average=${make_jobs}" \
        emerge --jobs='"${emerge_jobs}"' --load-average="${cpus}" \
        --emptytree @system
    emerge --depclean
    ' || stage3_exit="${?}"

# === Stage 3 Timeout & Completion Handling ===

if (( stage3_exit == 124 )); then
    log_warn "Stage 3 build timed out after ${TIMEOUT}"
    upload_binary_packages "${STAGE_DIR}" "${PROFILE}"
    if [[ -n "${RESUME_ID}" ]]; then
        publish_resume_stage "${STAGE_DIR}" "${PROFILE}" \
            "${RESUME_ID}" "stage3"
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3-init"
    fi
    unmount_repos
    remove_portage_configuration "${STAGE_DIR}"
    force_remove "${STAGE_DIR}"
    exit 124
elif (( stage3_exit != 0 )); then
    log_warn "Stage 3 build failed with exit code ${stage3_exit};" \
        "uploading built packages"
    if [[ -n "${RESUME_ID}" ]]; then
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3"
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3-init"
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage1"
    fi
    upload_binary_packages "${STAGE_DIR}" "${PROFILE}"
    unmount_repos
    remove_portage_configuration "${STAGE_DIR}"
    upload_portage_failure_logs "${stage3_exit}"
    force_remove "${STAGE_DIR}"
    exit "${stage3_exit}"
fi

unmount_repos
remove_portage_configuration "${STAGE_DIR}"

# === Artifact Upload & Cleanup ===

upload_binary_packages "${STAGE_DIR}" "${PROFILE}"
publish_stage_archive "${STAGE_DIR}" "${PROFILE}" "stage3"

if [[ -n "${RESUME_ID}" ]]; then
    clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage1"
    clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3-init"
    clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3"
fi

force_remove "${STAGE_DIR}"
