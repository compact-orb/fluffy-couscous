#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === CLI Arguments & Setup ===

required_commands=(
    "dirname"
    "mv"
    "nproc"
    "realpath"
)

source "$(realpath \
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/common.sh")"
source "$(realpath \
    "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../lib/build.sh")"

cli_define_option "SEED_ARCH" "-a|--arch" \
    "Stage seed architecture (defaults from --profile)" 0 ""
cli_define_option "SEED_NAME" "-n|--name" \
    "Stage seed tarball name (defaults for arm64/amd64)" 0 ""
cli_define_option "SEED_STAGE" "-s|--seed-stage" \
    "Custom stage3 profile to use as seed" 0 ""
cli_define_option "PROFILE" "-p|--profile" \
    "Profile in repository:profile format" 1
cli_define_flag "WORKAROUND" "-w|--workaround" \
    "Apply bootstrap workaround instead of full rebuild"
cli_define_option "TIMEOUT" "-t|--timeout" \
    "Timeout duration for emerge (e.g. 330m)" 0 ""
cli_define_option "START_TIME" "--start-time" \
    "Job start epoch timestamp in seconds" 0 ""
cli_define_option "RESUME_ID" "-r|--resume-id" \
    "Unique ID for resume snapshots" 0 ""
cli_define_flag "RESUME" "-R|--resume" \
    "Resume build from a saved snapshot" 0
cli_define_flag "JOBS" "-j|--jobs" \
    "Enable parallel emerge jobs using nproc (defaults to 1)" 0

cli_parse "${@}"
if [[ -z "${SEED_STAGE}" ]]; then
    if [[ -z "${SEED_ARCH}" ]]; then
        SEED_ARCH="$(get_profile_arch "${PROFILE}")"
    fi
    if [[ -z "${SEED_NAME}" ]]; then
        case "${SEED_ARCH}" in
            arm64|amd64) SEED_NAME="stage3-${SEED_ARCH}-systemd" ;;
        esac
    fi
fi
readonly SEED_ARCH SEED_NAME SEED_STAGE PROFILE WORKAROUND \
    TIMEOUT START_TIME RESUME_ID RESUME JOBS
init_timeout_deadline "${TIMEOUT}" "${START_TIME}"

emerge_jobs=1
if (( JOBS == 1 )); then
    emerge_jobs="$(nproc)"
fi
readonly emerge_jobs
cpus="$(nproc)"
make_jobs=$(( cpus > 1 ? cpus - 1 : 1 ))
readonly cpus make_jobs

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
        log_error "Specify --seed-stage, or --name" \
            "(and --arch if not defaulted from --profile)."
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
    elif has_resume_stage "${PROFILE}" "${RESUME_ID}" "seed-ready"; then
        resume_phase="seed-ready"
    elif has_resume_stage "${PROFILE}" "${RESUME_ID}" "seed-update"; then
        resume_phase="seed-update"
    else
        log_error "No resume snapshot found for ${PROFILE} (${RESUME_ID})"
        exit 1
    fi
fi

# === Phase 1 & 2: Stage 1 Bootstrapping ===

if [[ "${resume_phase}" != "stage3" && \
      "${resume_phase}" != "stage3-init" ]]; then
    need_seed_update=0
    seed_cmd=""

    case "${resume_phase}" in
        stage1|seed-ready|seed-update)
            if [[ "${resume_phase}" != "seed-ready" && \
                  ! -d "${SEED_DIR}/.criu" ]]; then
                log_error "CRIU checkpoint not found in ${SEED_DIR}"
                exit 1
            fi
            log_info "Resuming ${resume_phase} on mounted filesystem" \
                "for ${PROFILE}"
            mount_repos "${SEED_DIR}"
            install_secureboot_keys "${SEED_DIR}"
            if [[ "${resume_phase}" == "seed-update" ]]; then
                need_seed_update=1
            fi
            ;;
        "")
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
                need_seed_update=1
                seed_cmd='
                    MAKEOPTS="--jobs='"${make_jobs}"'"
                    MAKEOPTS+=" --load-average='"${make_jobs}"'"
                    export MAKEOPTS
                    emerge --jobs='"${emerge_jobs}"' \
                        --load-average='"${cpus}"' dev-lang/perl
                    emerge --deep --jobs='"${emerge_jobs}"' \
                        --load-average='"${cpus}"' \
                        --newuse --update @world
                    '
            else
                remove_portage_configuration "${SEED_DIR}"
                configure_portage "${SEED_DIR}" "${PROFILE}" "stage1"
                install_secureboot_keys "${SEED_DIR}"

                if [[ -z "${SEED_STAGE}" ]]; then
                    need_seed_update=1
                    seed_cmd='
                        MAKEOPTS="--jobs='"${make_jobs}"'"
                        MAKEOPTS+=" --load-average='"${make_jobs}"'"
                        export MAKEOPTS
                        emerge --deep --getbinpkg \
                            --jobs='"${emerge_jobs}"' \
                            --load-average='"${cpus}"' \
                            --newuse --update @world
                        '
                fi
            fi
            ;;
    esac

    if (( need_seed_update == 1 )); then
        seed_exit=0
        CHROOT_TIMEOUT="$(get_remaining_timeout "${TIMEOUT}")" \
            chroot_run "${SEED_DIR}" "${seed_cmd}" || seed_exit="${?}"

        if (( seed_exit == 124 )); then
            log_warn "Seed update timed out (${TIMEOUT} budget)"
            unmount_repos
            if [[ -n "${RESUME_ID}" ]]; then
                publish_resume_stage "${SEED_DIR}" "${PROFILE}" \
                    "${RESUME_ID}" "seed-update" || exit 1
                exit 0
            fi
            exit 124
        elif (( seed_exit != 0 )); then
            if [[ -n "${RESUME_ID}" ]]; then
                clear_resume_stage "${PROFILE}" "${RESUME_ID}" "seed-update"
            fi
            unmount_repos
            upload_portage_failure_logs "${seed_exit}"
            force_remove "${SEED_DIR}"
            exit "${seed_exit}"
        fi

        if [[ -n "${RESUME_ID}" ]] && ! has_enough_timeout 600; then
            log_info "Seed update finished with <= 10m remaining;" \
                "uploading seed-ready snapshot and stopping."
            unmount_repos
            publish_resume_stage "${SEED_DIR}" "${PROFILE}" \
                "${RESUME_ID}" "seed-ready" || exit 1
            clear_resume_stage "${PROFILE}" "${RESUME_ID}" "seed-update"
            exit 0
        fi
    fi

    if [[ "${resume_phase}" != "stage1" ]]; then
        # --- Toolchain Bootstrapping into /tmp/stage ---
        copy_file "${WORK_DIR}/bin/build.py" "${SEED_DIR}/tmp/build.py"
        create_directory "${SEED_STAGE_BIND_DIR}/etc/portage"

        chroot_run "${SEED_DIR}" '
            USE="build" emerge --nodeps --oneshot --root="/tmp/stage" \
                sys-apps/baselayout
            '
    fi

    stage1_exit=0
    CHROOT_TIMEOUT="$(get_remaining_timeout "${TIMEOUT}")" \
        chroot_run "${SEED_DIR}" '
        buildpkgs=$(/tmp/build.py)
        MAKEOPTS="--jobs='"${make_jobs}"' --load-average='"${make_jobs}"'" \
        emerge --jobs='"${emerge_jobs}"' --load-average='"${cpus}"' \
            --implicit-system-deps=n --oneshot --root="/tmp/stage" \
            ${buildpkgs}
        locale-gen --prefix "/tmp/stage"
        ' || stage1_exit="${?}"

    # --- Stage 1 Timeout & Failure Handling ---
    if (( stage1_exit == 124 )); then
        log_warn "Stage 1 build timed out (${TIMEOUT} budget)"
        unmount_repos
        if [[ -n "${RESUME_ID}" ]]; then
            publish_resume_stage "${SEED_DIR}" "${PROFILE}" \
                "${RESUME_ID}" "stage1" || exit 1
            clear_resume_stage "${PROFILE}" "${RESUME_ID}" \
                "seed-ready" "seed-update"
            exit 0
        fi
        exit 124
    elif (( stage1_exit != 0 )); then
        if [[ -n "${RESUME_ID}" ]]; then
            clear_resume_stage "${PROFILE}" "${RESUME_ID}" \
                "stage1" "seed-ready" "seed-update"
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
        log_info "Stage 1 finished." \
            "Uploading stage3-init snapshot and stopping."
        publish_resume_stage "${STAGE_DIR}" "${PROFILE}" \
            "${RESUME_ID}" "stage3-init" || exit 1
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" \
            "stage1" "seed-ready" "seed-update"
        exit 0
    fi
fi

# === Phase 3: Stage 3 Finalizing Rebuild ===

if [[ "${resume_phase}" == "stage3" ]]; then
    if [[ ! -d "${STAGE_DIR}/.criu" ]]; then
        log_error "CRIU checkpoint not found in ${STAGE_DIR}"
        exit 1
    fi
    log_info "Resuming stage3 on mounted filesystem for ${PROFILE}"
else
    if [[ "${resume_phase}" == "stage3-init" ]]; then
        log_info "Resuming stage3-init on mounted filesystem for ${PROFILE}"
    fi
    create_directory "${STAGE_DIR}/etc/portage"
    configure_portage "${STAGE_DIR}" "${PROFILE}" "stage3"
fi
mount_repos "${STAGE_DIR}"
install_portage_gpg_key "${STAGE_DIR}"
install_secureboot_keys "${STAGE_DIR}"
mount_binary_packages "${STAGE_DIR}" "${PROFILE}"

stage3_exit=0
CHROOT_TIMEOUT="$(get_remaining_timeout "${TIMEOUT}")" \
    chroot_run "${STAGE_DIR}" '
    emaint --fix binhost
    MAKEOPTS="--jobs='"${make_jobs}"' --load-average='"${make_jobs}"'" \
    emerge --jobs='"${emerge_jobs}"' --load-average='"${cpus}"' \
        --emptytree @system
    emerge --depclean
    ' || stage3_exit="${?}"

# === Stage 3 Timeout & Completion Handling ===

if (( stage3_exit == 124 )); then
    if [[ -n "${RESUME_ID}" ]]; then
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" "stage3-init"
    fi
    handle_build_timeout "${STAGE_DIR}" "${PROFILE}" \
        "${TIMEOUT}" "${RESUME_ID}"
elif (( stage3_exit != 0 )); then
    if [[ -n "${RESUME_ID}" ]]; then
        clear_resume_stage "${PROFILE}" "${RESUME_ID}" \
            "stage1" "stage3-init"
    fi
    handle_build_failure "${STAGE_DIR}" "${PROFILE}" \
        "${RESUME_ID}" "${stage3_exit}"
fi

finish_stage_build "${STAGE_DIR}" "${PROFILE}" "${RESUME_ID}" "stage3"

if [[ -n "${RESUME_ID}" ]]; then
    clear_resume_stage "${PROFILE}" "${RESUME_ID}" \
        "stage1" "stage3-init"
fi
