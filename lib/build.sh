# Sourced by build/CI scripts
# (bootstrap.sh, build.sh, build-install.sh, update.sh).
# Requires lib/common.sh to be loaded.

if [[ ! -v _COMMON_SH_INCLUDED ]]; then
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/common.sh")"
fi

required_commands+=(
    "aria2c"
    "awk"
    "basename"
    "btrfs"
    "chmod"
    "criu"
    "curl"
    "date"
    "dirname"
    "dmesg"
    "env"
    "find"
    "fstrim"
    "fusermount3" # Required by rclone mount
    "gpg"
    "gpgconf"
    "grep"
    "mknod"
    "mktemp"
    "mount"
    "pivot_root"
    "rclone"
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "sed"
    "setsid"
    "sleep"
    "storageto"
    "sync"
    "tail"
    "tar"
    "tr"
    "umount"
    "unshare"
    "xz" # Required by tar for .tar.xz archives
    "zstd"
)

# === Cloud Storage & Failure Logs ===

upload_to_storageto() {
    log_info "Uploading ${*} to storage.to"

    local token_args=()
    local temp_config_dir=""
    # storageto reads its API token from $XDG_CONFIG_HOME/storageto/token, so
    # write STORAGETO_KEY into a temporary directory when set.
    if [[ -n "${STORAGETO_KEY:-}" ]]; then
        temp_config_dir="$(mktemp --directory)"
        create_directory "${temp_config_dir}/storageto"
        printf "%s" "${STORAGETO_KEY}" > "${temp_config_dir}/storageto/token"
        chmod 0600 "${temp_config_dir}/storageto/token"
    else
        log_warn "STORAGETO_KEY is not set. Uploading anonymously."
        token_args+=("--no-token")
    fi

    local -a env_cmd=()
    if [[ -n "${temp_config_dir}" ]]; then
        env_cmd=(env XDG_CONFIG_HOME="${temp_config_dir}")
    fi

    local exit_code=0
    # Filter carriage-return progress output so CI logs only show final URLs.
    "${env_cmd[@]}" storageto upload \
        --expire="7d" "${token_args[@]}" "${@}" 2>&1 | \
        sed --expression='s/.*\r//' --expression='/%/d' \
            --expression='/^[[:space:]]*$/d' || exit_code="${?}"

    if [[ -n "${temp_config_dir}" ]]; then
        force_remove "${temp_config_dir}"
    fi
    return "${exit_code}"
}

upload_portage_failure_logs() {
    local exit_code="${1}"
    if (( exit_code == 124 )); then
        return 0
    fi
    if [[ -v _portage_failure_logs_uploaded ]]; then
        return 0
    fi
    _portage_failure_logs_uploaded=1

    local -a search_roots=()
    if [[ -v STAGE_DIR && -d "${STAGE_DIR}" ]]; then
        search_roots+=("${STAGE_DIR}")
    fi
    if [[ -v SEED_DIR && -d "${SEED_DIR}" ]]; then
        search_roots+=("${SEED_DIR}")
    fi
    if [[ -v TARGET_ROOT && -d "${TARGET_ROOT}" ]]; then
        search_roots+=("${TARGET_ROOT}")
    fi
    if [[ -v INSTALL_MOUNT_DIR && -d "${INSTALL_MOUNT_DIR}" ]]; then
        search_roots+=("${INSTALL_MOUNT_DIR}")
    fi

    local -a log_files=()
    local root
    for root in "${search_roots[@]}"; do
        local portage_dir="${root}/var/tmp/portage"
        if [[ -d "${portage_dir}" ]]; then
            # Depth 3 matches <category>/<package>-<ver>/temp where Portage
            # stores build.log and environment dumps for failed merges.
            while IFS= read -r -d '' temp_dir; do
                log_files+=("${temp_dir}")
                local build_log="${temp_dir}/build.log"
                if [[ -f "${build_log}" ]]; then
                    local rel_pkg="${temp_dir#"${portage_dir}/"}"
                    rel_pkg="${rel_pkg%/temp}"
                    log_warn "=== Failed package build.log (${rel_pkg}) ==="
                    tail --lines=100 "${build_log}" >&2 || true
                fi
            done < <(find "${portage_dir}" -mindepth 3 -maxdepth 3 \
                -type d -name "temp" -print0 2>/dev/null)
        fi
        if [[ -f "${root}/var/log/emerge.log" ]]; then
            log_files+=("${root}/var/log/emerge.log")
            log_warn "=== Last 50 lines of Portage emerge.log ==="
            tail --lines=50 "${root}/var/log/emerge.log" >&2 || true
        fi
        if [[ -f "${root}/var/tmp/.fluffy-chroot.exit" ]]; then
            local chroot_rc
            chroot_rc="$(<"${root}/var/tmp/.fluffy-chroot.exit")"
            log_warn "=== Chroot exit code file: ${chroot_rc} ==="
        fi
        if [[ -f "${root}/var/tmp/.fluffy-chroot.log" ]]; then
            log_files+=("${root}/var/tmp/.fluffy-chroot.log")
            log_warn "=== Last 100 lines of chroot log ==="
            tail --lines=100 "${root}/var/tmp/.fluffy-chroot.log" >&2 || true
        fi
        if [[ -f "${root}/.criu/restore.log" ]]; then
            log_files+=("${root}/.criu/restore.log")
        fi
        if [[ -f "${root}/.criu/dump.log" ]]; then
            log_files+=("${root}/.criu/dump.log")
        fi
    done

    if (( ${#log_files[@]} == 0 )); then
        return 0
    fi

    log_warn "Build failed; gathering Portage failure logs for upload..."
    local archive_dir archive_name archive
    archive_dir="$(mktemp --directory)"
    archive_name="portage-failure-logs-$(date +%Y%m%d%H%M%S).tar.zst"
    archive="${archive_dir}/${archive_name}"

    tar --create --file="${archive}" \
        --use-compress-program="zstd --long=31 --threads=0 -9" \
        --directory="/" \
        "${log_files[@]#/}" 2>/dev/null || true

    if [[ -f "${archive}" && -s "${archive}" ]]; then
        if [[ -v S3_BUCKET_NAME && -n "${S3_BUCKET_NAME}" ]] && \
            type -t s3_rclone >/dev/null 2>&1; then
            log_info "Uploading failure logs to S3..."
            s3_rclone copy "${archive}" \
                ":s3:${S3_BUCKET_NAME}/logs" || true
        fi
        if command -v storageto >/dev/null 2>&1; then
            upload_to_storageto "${archive}" || true
        fi
    fi

    force_remove "${archive_dir}"
}

register_failure_hook upload_portage_failure_logs

# === Signing & Security ===

import_signing_key() {
    if [[ -v _signing_key_fingerprint ]]; then
        return
    fi

    if [[ -z "${SIGNING_KEY:-}" ]]; then
        log_error "SIGNING_KEY is not set or empty"
        return 1
    fi

    log_info "Importing PGP signing key"

    _signing_key_fingerprint=$(gpg --show-keys --with-colons \
        <<< "${SIGNING_KEY}" | \
        awk -F: '/^fpr/ {print $10; exit}')

    if [[ -z "${_signing_key_fingerprint}" ]]; then
        log_error "Failed to determine PGP signing key fingerprint"
        return 1
    fi

    gpg --import --quiet <<< "${SIGNING_KEY}"

    printf "%s\n" "${_signing_key_fingerprint}:6:" | \
        gpg --batch --import-ownertrust --quiet
}

# Installs the private signing key into an isolated keyring (/var/lib/portage/
# gnupg-sign) used only by root during binpkg creation; stripped before packing.
install_portage_gpg_key() {
    local target_root="${1}"
    log_info "Applying Portage signing key for ${target_root}"

    import_signing_key

    local portage_gnupg_signing_dir="${target_root}${PORTAGE_GPG_DIR}"
    create_directory "${portage_gnupg_signing_dir}"
    chmod 0700 "${portage_gnupg_signing_dir}"

    gpg --batch --export-secret-keys "${_signing_key_fingerprint}" | \
        gpg --batch --homedir "${portage_gnupg_signing_dir}" --import
    gpgconf --homedir "${portage_gnupg_signing_dir}" --kill all \
        2> /dev/null || true

    if [[ -f "${target_root}/etc/portage/make.conf" ]] && \
        ! grep --quiet "BINPKG_GPG_SIGNING_KEY" \
            "${target_root}/etc/portage/make.conf"; then
        printf "%s\n" \
            "BINPKG_GPG_SIGNING_KEY=\"${_signing_key_fingerprint}\"" \
            >> "${target_root}/etc/portage/make.conf"
    fi
}

sign_file() {
    local file="${1}"
    local sig_file="${2:-${file}.sig}"

    import_signing_key

    log_info "Signing ${file}"
    gpg --batch --yes --detach-sign \
        --local-user "${_signing_key_fingerprint}" \
        --output "${sig_file}" "${file}"
}

install_secureboot_keys() {
    local target_root="${1}"

    if [[ ! -v SECUREBOOT_KEY ]] || [[ ! -v SECUREBOOT_CERT ]]; then
        return
    fi

    log_info "Applying Secure Boot keys for ${target_root}"

    local secureboot_dir="${target_root}${PORTAGE_SECUREBOOT_DIR}"
    create_directory "${secureboot_dir}"
    chmod 0700 "${secureboot_dir}"

    create_file "${secureboot_dir}/db.key" "${SECUREBOOT_KEY}"
    chmod 0600 "${secureboot_dir}/db.key"

    create_file "${secureboot_dir}/db.pem" "${SECUREBOOT_CERT}"
    chmod 0644 "${secureboot_dir}/db.pem"

    if [[ -f "${target_root}/etc/portage/make.conf" ]] && \
        ! grep --quiet "SECUREBOOT_SIGN_KEY" \
            "${target_root}/etc/portage/make.conf"; then
        printf "%s\n" \
            "SECUREBOOT_SIGN_KEY=\"${PORTAGE_SECUREBOOT_DIR}/db.key\"" \
            "SECUREBOOT_SIGN_CERT=\"${PORTAGE_SECUREBOOT_DIR}/db.pem\"" \
            "MODULES_SIGN_KEY=\"${PORTAGE_SECUREBOOT_DIR}/db.key\"" \
            "MODULES_SIGN_CERT=\"${PORTAGE_SECUREBOOT_DIR}/db.pem\"" \
            >> "${target_root}/etc/portage/make.conf"
    fi
}

# === Stage Downloading and Extraction ===

fetch_seed_stage() {
    local output_dir="${1}"
    local architecture="${2}"
    local name="${3}"

    log_info "Downloading and extracting latest ${name} to ${output_dir}"

    import_bundled_keys

    create_directory "${output_dir}"

    local autobuild_url="${GENTOO_MIRROR_URL}/releases/${architecture}"
    autobuild_url+="/autobuilds/latest-${name}.txt"
    local seed_path
    seed_path=$(curl --silent "${autobuild_url}" |
        gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}')

    local latest_autobuild_path="${GENTOO_MIRROR_URL}/releases/${architecture}"
    latest_autobuild_path+="/autobuilds/${seed_path}"

    local download_dir
    download_dir="$(mktemp --directory)"

    local seed_tarball="${download_dir}/$(basename "${seed_path}")"

    log_info "Downloading to ${seed_tarball} and ${seed_tarball}.asc"
    aria2c --file-allocation="none" --force-sequential \
        --max-concurrent-downloads="4" --max-connection-per-server="4" \
        --max-tries="3" --dir="${download_dir}" --quiet \
        "${latest_autobuild_path}" "${latest_autobuild_path}.asc"

    verify_file "${seed_tarball}.asc" "${seed_tarball}"

    remove_file "${seed_tarball}.asc"

    log_info "Extracting ${seed_tarball} to ${output_dir}"
    tar_extract "${seed_tarball}" "${output_dir}"

    remove_file "${seed_tarball}"
    force_remove "${download_dir}"
}

has_resume_stage() {
    local profile="${1}"
    local resume_id="${2}"
    local stage_type="${3}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local stage_prefix="${stage_type}-${repo_profile//\//-}"
    local image_filename="${stage_prefix}-resume-${resume_id}.img.zst"

    local output
    output="$(s3_rclone lsf \
        ":s3:${S3_BUCKET_NAME}/resumes/${image_filename}" 2> /dev/null || true)"
    [[ "${output//$'\r'/}" == "${image_filename}" ]]
}

# === Stage Uploading ===

upload_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Uploading binary packages from ${target_root}"

    local portage_binpkgs_dir="${target_root}/var/cache/binpkgs"
    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    s3_rclone copy "${portage_binpkgs_dir}" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}"
}

publish_stage_archive() {
    local target_root="${1}"
    local profile="${2}"
    local stage_type="${3}"
    log_info "Uploading Gentoo ${stage_type} from ${target_root}"

    import_signing_key

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local profile_name="${repo_profile//\//-}"
    local stage_filename="${stage_type}-${profile_name}.tar.zst"
    local sig_filename="${stage_filename}.sig"
    local archive_dir
    archive_dir="$(mktemp --directory)"
    local stage_file="${archive_dir}/${stage_filename}"
    local sig_file="${archive_dir}/${sig_filename}"
    log_info "Creating stage archive ${stage_file}"
    # Strip signing keys, Secure Boot keys, kernel/boot artifacts, and runtime
    # caches so the published stage archive is clean and redistributable.
    tar_create "${stage_file}" "${target_root}" \
        --exclude=".${PORTAGE_GPG_DIR}" \
        --exclude=".${PORTAGE_SECUREBOOT_DIR}" \
        --exclude="./.criu" \
        --exclude="./.oldroot" \
        --exclude="./boot/*" \
        --exclude="./etc/kernel" \
        --exclude="./etc/machine-id" \
        --exclude="./etc/resolv.conf" \
        --exclude="./root/*" \
        --exclude="./tmp/*" \
        --exclude="./var/cache/*" \
        --exclude="./var/db/repos/*" \
        --exclude="./var/lib/systemd/catalog/database" \
        --exclude="./var/log/*" \
        --exclude="./var/tmp/*" \
        "."
    sign_file "${stage_file}" "${sig_file}"

    log_info "Uploading stage archive ${stage_file}"
    s3_rclone copy "${stage_file}" \
        ":s3:${S3_BUCKET_NAME}"

    log_info "Uploading stage archive signature ${sig_file}"
    s3_rclone copy "${sig_file}" \
        ":s3:${S3_BUCKET_NAME}"

    force_remove "${stage_file}"
    force_remove "${sig_file}"
    force_remove "${archive_dir}"
}

publish_resume_stage() {
    local target_root="${1}"
    local profile="${2}"
    local resume_id="${3}"
    local stage_type="${4}"
    log_info "Uploading ${stage_type} resume filesystem image for ${profile}"

    import_signing_key

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local stage_prefix="${stage_type}-${repo_profile//\//-}"
    local image_filename="${stage_prefix}-resume-${resume_id}.img.zst"
    local sig_filename="${image_filename}.sig"
    local archive_dir
    archive_dir="$(mktemp --directory)"
    local image_file="${archive_dir}/${image_filename}"
    local sig_file="${archive_dir}/${sig_filename}"

    # Strip private signing and Secure Boot keys before snapshotting /btrfs.img.
    force_remove "${target_root}${PORTAGE_GPG_DIR}"
    force_remove "${target_root}${PORTAGE_SECUREBOOT_DIR}"

    fstrim /mnt/btrfs 2> /dev/null || true
    btrfs filesystem sync /mnt/btrfs 2> /dev/null || true
    sync
    mount --options "remount,ro" /mnt/btrfs 2> /dev/null || true

    log_info "Creating resume filesystem image ${image_file}"
    zstd --sparse --force --threads=0 /btrfs.img -o "${image_file}"

    sign_file "${image_file}" "${sig_file}"

    log_info "Uploading resume filesystem image ${image_file}"
    s3_rclone copy "${image_file}" \
        ":s3:${S3_BUCKET_NAME}/resumes"

    log_info "Uploading resume image signature ${sig_file}"
    s3_rclone copy "${sig_file}" \
        ":s3:${S3_BUCKET_NAME}/resumes"

    force_remove "${image_file}"
    force_remove "${sig_file}"
    force_remove "${archive_dir}"
}

clear_resume_stage() {
    local profile="${1}"
    local resume_id="${2}"
    local stage_type="${3}"
    log_info "Removing ${stage_type} snapshot for ${profile} (${resume_id})"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local stage_prefix="${stage_type}-${repo_profile//\//-}"
    local image_filename="${stage_prefix}-resume-${resume_id}.img.zst"

    s3_rclone delete ":s3:${S3_BUCKET_NAME}/resumes/${image_filename}" \
        > /dev/null 2>&1 || true
    s3_rclone delete ":s3:${S3_BUCKET_NAME}/resumes/${image_filename}.sig" \
        > /dev/null 2>&1 || true
}

# === Binary Package Caching Mount ===

_active_binpkg_mounts=()
# Mounts the remote S3 binary package directory read-only via rclone and layers
# a writable local OverlayFS on /var/cache/binpkgs so Portage can read existing
# binpkgs on demand and write new/updated packages locally before syncing back.
mount_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Mounting binary packages for ${target_root}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local binpkgs_dir="${target_root}/var/cache/binpkgs"
    local host_binpkgs_base="${BUILD_DIR}/binpkgs"
    create_directory "${host_binpkgs_base}"

    local lowerdir="${host_binpkgs_base}/lower"
    create_directory "${lowerdir}"
    local upperdir="${host_binpkgs_base}/upper"
    create_directory "${upperdir}"
    local workdir="${host_binpkgs_base}/work"
    create_directory "${workdir}"

    local rc_sock="${host_binpkgs_base}/rc.sock"
    force_remove "${rc_sock}"
    log_info "Mounting ${lowerdir}"
    s3_rclone mount --attr-timeout "24h" --buffer-size "64M" \
        --dir-cache-time "24h" --poll-interval "0" --read-only \
        --rc --rc-addr "unix://${rc_sock}" --rc-no-auth \
        --vfs-cache-max-age "24h" \
        --vfs-cache-mode "full" \
        --vfs-read-ahead "128M" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}" "${lowerdir}" \
        > /dev/null 2>&1 &

    local timeout=300
    while [[ "$(</proc/mounts)" != *" ${lowerdir} "* ]]; do
        if (( timeout <= 0 )); then break; fi
        sleep 0.1
        ((timeout--))
    done
    if [[ "$(</proc/mounts)" != *" ${lowerdir} "* ]]; then
        log_error "Timed out waiting for rclone mount to become ready"
        return 1
    fi

    # Manually add rclone mount to the list of mounts to be unmounted later
    _active_binpkg_mounts+=("${lowerdir}")

    # Pre-warm the FUSE directory cache in a single request so Portage
    # dependency resolution does not stall on per-directory S3 listings.
    log_info "Pre-loading metadata for ${lowerdir}"
    rclone rc --no-output --unix-socket "${rc_sock}" "vfs/refresh" \
        "recursive=true"

    create_directory "${binpkgs_dir}"
    managed_mount "_active_binpkg_mounts" --options \
        "lowerdir=${lowerdir},upperdir=${upperdir},workdir=${workdir}" \
        --types "overlay" "overlay" "${binpkgs_dir}"
}

unmount_binary_packages() {
    log_info "Unmounting binary packages"
    managed_unmount_all "_active_binpkg_mounts"
    force_remove "${BUILD_DIR}/binpkgs"
}

upload_mounted_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Uploading mounted binary packages from ${target_root}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local binpkgs_dir="${target_root}/var/cache/binpkgs"

    # Sync the merged OverlayFS mount so newly built packages are uploaded and
    # any packages removed or replaced in the upper layer are pruned on S3.
    s3_rclone sync "${binpkgs_dir}" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}"
}

# === CRIU Chroot & Resumption Execution ===

parse_duration_seconds() {
    local duration="${1}"
    if [[ "${duration}" =~ ^([0-9]+)([smhd]?)$ ]]; then
        local val="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "${unit}" in
            ""|s) printf "%s\n" "${val}" ;;
            m) printf "%s\n" "$(( val * 60 ))" ;;
            h) printf "%s\n" "$(( val * 3600 ))" ;;
            d) printf "%s\n" "$(( val * 86400 ))" ;;
        esac
    else
        log_error "Invalid timeout duration: ${duration}"
        return 1
    fi
}

prepare_criu_chroot_filesystem() {
    local target_root="${1}"

    create_directory "${target_root}/etc"
    if [[ ! -L "${target_root}/etc/resolv.conf" ]]; then
        cp --dereference --force "/etc/resolv.conf" \
            "${target_root}/etc/resolv.conf"
    fi

    create_directory "${target_root}/proc"
    create_directory "${target_root}/sys"
    create_directory "${target_root}/run"
    create_directory "${target_root}/run/lock"
    chmod 1777 "${target_root}/run/lock"
    create_directory "${target_root}/dev"
    create_directory "${target_root}/dev/pts"
    create_directory "${target_root}/dev/shm"
    chmod 1777 "${target_root}/dev/shm"
    create_directory "${target_root}/var/cache/binpkgs"
    create_directory "${target_root}/var/tmp"
    create_directory "${target_root}/.oldroot"

    [[ -c "${target_root}/dev/null" ]] || \
        mknod --mode="0666" "${target_root}/dev/null" c 1 3
    [[ -c "${target_root}/dev/zero" ]] || \
        mknod --mode="0666" "${target_root}/dev/zero" c 1 5
    [[ -c "${target_root}/dev/full" ]] || \
        mknod --mode="0666" "${target_root}/dev/full" c 1 7
    [[ -c "${target_root}/dev/random" ]] || \
        mknod --mode="0666" "${target_root}/dev/random" c 1 8
    [[ -c "${target_root}/dev/urandom" ]] || \
        mknod --mode="0666" "${target_root}/dev/urandom" c 1 9
    [[ -c "${target_root}/dev/tty" ]] || \
        mknod --mode="0666" "${target_root}/dev/tty" c 5 0
    [[ -c "${target_root}/dev/console" ]] || \
        mknod --mode="0600" "${target_root}/dev/console" c 5 1

    create_symbolic_link "pts/ptmx" "${target_root}/dev/ptmx"
    create_symbolic_link "/proc/self/fd" "${target_root}/dev/fd"
    create_symbolic_link "/proc/self/fd/0" "${target_root}/dev/stdin"
    create_symbolic_link "/proc/self/fd/1" "${target_root}/dev/stdout"
    create_symbolic_link "/proc/self/fd/2" "${target_root}/dev/stderr"
}

collect_criu_ext_mount_maps() {
    local real_target_root="${1}"
    local -n dump_args_ref="${2}"
    local -n restore_args_ref="${3}"

    dump_args_ref=()
    restore_args_ref=()

    local -A seen_mounts=()
    local m_dev m_point m_rest
    while IFS=" " read -r m_dev m_point m_rest; do
        if [[ "${m_point}" == "${real_target_root}/"* ]]; then
            local rel_mount="${m_point#"${real_target_root}"}"
            case "${rel_mount}" in
                /proc|/proc/*|/dev|/dev/*|/sys|/sys/*|/run|/run/*|/.oldroot*)
                    continue
                    ;;
            esac
            if [[ -v seen_mounts["${rel_mount}"] ]]; then
                continue
            fi
            seen_mounts["${rel_mount}"]=1
            local mount_key="${rel_mount#/}"
            mount_key="${mount_key//\//_}"
            dump_args_ref+=(--ext-mount-map "${rel_mount}:${mount_key}")
            restore_args_ref+=(
                --ext-mount-map "${mount_key}:${real_target_root}${rel_mount}"
            )
        fi
    done < /proc/mounts
}

wait_for_criu_safe_point() {
    local real_target_root="${1}"

    # Wait up to 600 seconds if a package is actively writing to
    # /var/cache/binpkgs, fetching distfiles, or invoking gpg/signing keys so
    # no binary package or excluded key file is open during criu dump.
    local attempt
    for (( attempt=0; attempt<1200; attempt++ )); do
        local unsafe=0
        local p
        for p in /proc/[0-9]*; do
            if ! is_chroot_process "${p}" "${real_target_root}"; then
                continue
            fi
            local exe
            exe="$(basename "$(readlink "${p}/exe" 2> /dev/null)" \
                2> /dev/null || true)"
            case "${exe}" in
                gpg-agent|scdaemon|dirmngr)
                    continue
                    ;;
                gpg|gpgsm|wget|curl|aria2c)
                    unsafe=1
                    break
                    ;;
                bash|sh)
                    local cmdline
                    cmdline="$(tr '\0' ' ' < "${p}/cmdline" 2> /dev/null \
                        || true)"
                    if [[ "${cmdline}" == *"ebuild.sh"* && ( \
                        "${cmdline}" == *"pretend"* || \
                        "${cmdline}" == *"setup"* || \
                        "${cmdline}" == *"qmerge"* || \
                        "${cmdline}" == *"preinst"* || \
                        "${cmdline}" == *"postinst"* || \
                        "${cmdline}" == *"prerm"* || \
                        "${cmdline}" == *"postrm"* ) ]]; then
                        unsafe=1
                        break
                    fi
                    ;;
            esac
            local fd fd_target
            for fd in "${p}/fd/"*; do
                fd_target="$(readlink "${fd}" 2> /dev/null || true)"
                if [[ "${fd_target}" == *"/var/cache/binpkgs"* || \
                    "${fd_target}" == *"/build/binpkgs/"* || \
                    "${fd_target}" == *"${PORTAGE_GPG_DIR}"* || \
                    "${fd_target}" == *"${PORTAGE_SECUREBOOT_DIR}"* ]]; then
                    unsafe=1
                    break 2
                fi
            done
        done
        if (( unsafe == 0 )); then
            break
        fi
        sleep 0.5
    done

    # Terminate any idle gpg-agent/scdaemon/dirmngr inside the namespace and
    # wait for them to exit before dumping.
    local p exe
    for p in /proc/[0-9]*; do
        if is_chroot_process "${p}" "${real_target_root}"; then
            exe="$(basename "$(readlink "${p}/exe" 2> /dev/null)" \
                2> /dev/null || true)"
            case "${exe}" in
                gpg-agent|scdaemon|dirmngr)
                    kill -s "TERM" "${p##*/}" 2> /dev/null || true
                    ;;
            esac
        fi
    done

    for (( attempt=0; attempt<20; attempt++ )); do
        local has_agent=0
        for p in /proc/[0-9]*; do
            if is_chroot_process "${p}" "${real_target_root}"; then
                exe="$(basename "$(readlink "${p}/exe" 2> /dev/null)" \
                    2> /dev/null || true)"
                case "${exe}" in
                    gpg-agent|scdaemon|dirmngr)
                        has_agent=1
                        break
                        ;;
                esac
            fi
        done
        if (( has_agent == 0 )); then
            break
        fi
        sleep 0.2
    done

    # Clean up any lingering agent sockets so future invocations after restore
    # never encounter stale sockets.
    rm --force \
        "${real_target_root}/root/.gnupg/S."* \
        "${real_target_root}${PORTAGE_GPG_DIR}/S."* 2> /dev/null || true
}

chroot_run_criu() {
    local real_target_root
    real_target_root="$(realpath "${1}")"
    shift

    modprobe --all \
        af_packet_diag fuse inet_diag netlink_diag overlay raw_diag \
        tcp_diag udp_diag unix_diag 2> /dev/null || true

    prepare_criu_chroot_filesystem "${real_target_root}"

    local criu_dir="${real_target_root}/.criu"
    local log_file="${real_target_root}/var/tmp/.fluffy-chroot.log"
    local exit_file="${real_target_root}/var/tmp/.fluffy-chroot.exit"
    local cmd_file="${real_target_root}/var/tmp/.fluffy-chroot-cmd.sh"

    local -a ext_dump_args=()
    local -a ext_restore_args=()
    collect_criu_ext_mount_maps "${real_target_root}" \
        ext_dump_args ext_restore_args

    local timeout_secs=0
    if [[ -v CHROOT_TIMEOUT && -n "${CHROOT_TIMEOUT}" ]]; then
        timeout_secs="$(parse_duration_seconds "${CHROOT_TIMEOUT}")"
    fi

    local ns_init_pid=""
    local unshare_pid=""

    if [[ -d "${criu_dir}" ]]; then
        log_info "Restoring CRIU checkpoint for ${real_target_root}"
        rm --force "${exit_file}"
        rm --force \
            "${real_target_root}/root/.gnupg/S."* \
            "${real_target_root}${PORTAGE_GPG_DIR}/S."* 2> /dev/null || true

        local pidfile="${criu_dir}/restore.pid"
        rm --force "${pidfile}"
        if ! criu restore \
            --images-dir "${criu_dir}" \
            --root "${real_target_root}" \
            --restore-detached \
            --pidfile "${pidfile}" \
            --file-locks \
            --link-remap \
            --tcp-close \
            --cpu-cap="none" \
            "${ext_restore_args[@]}" \
            --verbosity=4 --log-file="restore.log"; then
            if [[ -f "${criu_dir}/restore.log" ]]; then
                tail --lines=50 "${criu_dir}/restore.log" >&2 || true
            fi
            log_error "CRIU restore failed for ${real_target_root}"
            return 1
        fi
        ns_init_pid="$(<"${pidfile}")"
        log_info "Restored CRIU process tree (PID ${ns_init_pid})"
    else
        rm --force "${exit_file}" "${log_file}"
        create_empty_file "${log_file}"

        create_file "${cmd_file}" "#!/bin/bash
export TERM=\"dumb\"
exec < /dev/null >> /var/tmp/.fluffy-chroot.log 2>&1
set +e
(
    source /etc/profile 2> /dev/null || true
    set -e
    ${*}
)
rc=\$?
printf \"%s\n\" \"\${rc}\" > /var/tmp/.fluffy-chroot.exit
exit \"\${rc}\""
        chmod 0755 "${cmd_file}"

        unshare --pid --fork setsid unshare --mount --uts --ipc /bin/bash -c "
            set -e
            mount --make-rprivate /
            mount --rbind '${real_target_root}' '${real_target_root}'
            cd '${real_target_root}'
            pivot_root . .oldroot
            mount --types proc proc /proc
            mount --types devpts \
                --options newinstance,ptmxmode=0666,mode=0620 devpts /dev/pts
            umount --lazy /.oldroot
            exec /bin/bash /var/tmp/.fluffy-chroot-cmd.sh
        " < /dev/null > /dev/null 2>&1 &
        unshare_pid="${!}"

        local attempt
        for (( attempt=0; attempt<100; attempt++ )); do
            ns_init_pid="$(awk '{print $1; exit}' \
                "/proc/${unshare_pid}/task/${unshare_pid}/children" \
                2> /dev/null || true)"
            if [[ -n "${ns_init_pid}" ]] && \
                is_chroot_process "/proc/${ns_init_pid}" \
                    "${real_target_root}"; then
                break
            fi
            if ! kill -0 "${unshare_pid}" 2> /dev/null; then
                break
            fi
            sleep 0.05
        done

        if [[ -z "${ns_init_pid}" && ! -f "${exit_file}" ]]; then
            wait "${unshare_pid}" 2> /dev/null || true
            log_error "Failed to start CRIU namespace for ${real_target_root}"
            return 1
        fi
    fi

    local tail_start_arg="--lines=+1"
    if [[ -f "${criu_dir}/restore.log" ]]; then
        tail_start_arg="--lines=0"
    fi
    tail --follow=name --retry "${tail_start_arg}" "${log_file}" 2> /dev/null &
    local tail_pid="${!}"

    local start_secs="${SECONDS}"
    local timed_out=0

    while [[ -n "${ns_init_pid}" ]] && \
        kill -0 "${ns_init_pid}" 2> /dev/null; do
        if (( timeout_secs > 0 && \
            (SECONDS - start_secs) >= timeout_secs )); then
            timed_out=1
            break
        fi
        sleep 1
    done

    if (( timed_out == 1 )) && [[ -n "${ns_init_pid}" ]] && \
        kill -0 "${ns_init_pid}" 2> /dev/null; then
        log_warn "Timeout (${CHROOT_TIMEOUT}) reached; checkpointing with CRIU"
        wait_for_criu_safe_point "${real_target_root}"

        if kill -0 "${ns_init_pid}" 2> /dev/null; then
            kill "${tail_pid}" 2> /dev/null || true
            wait "${tail_pid}" 2> /dev/null || true

            force_remove "${criu_dir}"
            create_directory "${criu_dir}"

            if ! criu dump \
                --tree "${ns_init_pid}" \
                --images-dir "${criu_dir}" \
                --file-locks \
                --link-remap \
                --ghost-limit "1G" \
                --tcp-close \
                --network-lock "skip" \
                "${ext_dump_args[@]}" \
                --verbosity=4 --log-file="dump.log"; then
                if [[ -f "${criu_dir}/dump.log" ]]; then
                    tail --lines=50 "${criu_dir}/dump.log" >&2 || true
                fi
                force_remove "${criu_dir}"
                kill_chroot_processes "${real_target_root}"
                if [[ -n "${unshare_pid}" ]]; then
                    wait "${unshare_pid}" 2> /dev/null || true
                fi
                log_error "CRIU dump failed for ${real_target_root}"
                return 1
            fi

            log_info "CRIU checkpoint saved to ${criu_dir}"
            if [[ -n "${unshare_pid}" ]]; then
                wait "${unshare_pid}" 2> /dev/null || true
            fi
            kill_chroot_processes "${real_target_root}"
            return 124
        fi
        log_info "Chroot process finished while waiting for CRIU safe point"
    fi

    if [[ -n "${unshare_pid}" ]]; then
        wait "${unshare_pid}" 2> /dev/null || true
    fi
    sleep 0.2
    kill "${tail_pid}" 2> /dev/null || true
    wait "${tail_pid}" 2> /dev/null || true

    local exit_code=1
    if [[ -f "${exit_file}" ]]; then
        exit_code="$(<"${exit_file}")"
    fi

    if (( exit_code != 0 )); then
        log_warn "Chroot execution failed with exit code ${exit_code}"
        if [[ ! -f "${exit_file}" ]]; then
            log_warn "Exit code file (${exit_file}) NOT FOUND"
        fi
        log_warn "Kernel dmesg (last 30 lines):"
        dmesg --ctime 2> /dev/null | tail --lines=30 >&2 || true
        if [[ -f "${criu_dir}/restore.log" ]]; then
            log_warn "CRIU restore log output:"
            tail --lines=100 "${criu_dir}/restore.log" >&2 || true
        fi
        if [[ -f "${log_file}" ]]; then
            log_warn "Chroot command log output:"
            tail --lines=200 "${log_file}" >&2 || true
        fi
    else
        rm --force "${cmd_file}" "${exit_file}" "${log_file}"
        force_remove "${criu_dir}"
    fi
    rmdir "${real_target_root}/.oldroot" 2> /dev/null || true
    kill_chroot_processes "${real_target_root}"

    return "${exit_code}"
}

# === Stage Build Lifecycle ===

prepare_stage_environment() {
    local stage_dir="${1}"
    local profile="${2}"
    local resume="${3}"
    local resume_id="${4}"

    if (( resume == 1 )); then
        if [[ -z "${resume_id}" ]]; then
            log_error "Resume requested but no resume ID provided"
            exit 1
        fi
        if ! has_resume_stage "${profile}" "${resume_id}" "stage3"; then
            log_error "Resume snapshot for ${profile} (${resume_id}) not found"
            exit 1
        fi
        if [[ ! -d "${stage_dir}/.criu" ]]; then
            log_error "CRIU checkpoint not found in ${stage_dir}"
            exit 1
        fi
        log_info "Resuming on mounted filesystem for ${profile}"
    else
        fetch_project_stage "${stage_dir}" "${profile}" "stage3"
        configure_portage "${stage_dir}" "${profile}" "stage3"
    fi

    mount_repos "${stage_dir}"
    install_portage_gpg_key "${stage_dir}"
    install_secureboot_keys "${stage_dir}"
    mount_binary_packages "${stage_dir}" "${profile}"
}

handle_build_timeout() {
    local stage_dir="${1}"
    local profile="${2}"
    local timeout="${3}"
    local resume_id="${4}"

    log_warn "Build timed out after ${timeout}"
    upload_mounted_binary_packages "${stage_dir}" "${profile}"
    unmount_binary_packages
    unmount_repos
    if [[ -n "${resume_id}" ]]; then
        publish_resume_stage "${stage_dir}" "${profile}" "${resume_id}" \
            "stage3" || exit 1
        exit 0
    fi
    exit 124
}

handle_build_failure() {
    local stage_dir="${1}"
    local profile="${2}"
    local resume_id="${3}"
    local exit_code="${4}"

    log_warn "Build failed with exit code ${exit_code};" \
        "uploading built packages"
    if [[ -n "${resume_id}" ]]; then
        clear_resume_stage "${profile}" "${resume_id}" "stage3"
    fi
    upload_mounted_binary_packages "${stage_dir}" "${profile}"
    unmount_binary_packages
    unmount_repos
    remove_portage_configuration "${stage_dir}"
    upload_portage_failure_logs "${exit_code}"
    force_remove "${stage_dir}"
    exit "${exit_code}"
}

finish_stage_build() {
    local stage_dir="${1}"
    local profile="${2}"
    local resume_id="${3}"
    local publish_stage="${4}"

    unmount_repos
    remove_portage_configuration "${stage_dir}"
    upload_mounted_binary_packages "${stage_dir}" "${profile}"
    unmount_binary_packages

    if [[ -n "${publish_stage}" ]]; then
        publish_stage_archive "${stage_dir}" "${profile}" "${publish_stage}"
    fi

    if [[ -n "${resume_id}" ]]; then
        clear_resume_stage "${profile}" "${resume_id}" "stage3"
    fi

    force_remove "${stage_dir}"
}
