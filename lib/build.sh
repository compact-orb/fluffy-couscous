# Sourced by build/CI scripts
# (bootstrap.sh, build.sh, build-install.sh, update.sh).
# Requires lib/common.sh to be loaded.

if [[ ! -v _COMMON_SH_INCLUDED ]]; then
    source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/common.sh")"
fi

required_commands+=(
    "aria2c"
    "basename"
    "curl"
    "date"
    "fusermount3" # Required by rclone mount
    "mktemp"
    "rclone"
    "sed"
    "sleep"
    "storageto"
    "tar"
    "xz" # Required by tar for .tar.xz archives
    "zstd"
)

# === S3 & Cloud Storage ===

s3_rclone() {
    rclone \
        --s3-access-key-id "${S3_ACCESS_KEY_ID}" \
        --s3-endpoint "${S3_ENDPOINT}" \
        --s3-provider "Other" \
        --s3-region "${S3_REGION}" \
        --s3-secret-access-key "${S3_SECRET_ACCESS_KEY}" \
        --transfers "16" \
        --verbose \
        "${@}"
}

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
    local -a search_roots=()
    if [[ -v STAGE_DIR && -d "${STAGE_DIR}/var/tmp/portage" ]]; then
        search_roots+=("${STAGE_DIR}")
    fi
    if [[ -v SEED_DIR && -d "${SEED_DIR}/var/tmp/portage" ]]; then
        search_roots+=("${SEED_DIR}")
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
            done < <(find "${portage_dir}" -mindepth 3 -maxdepth 3 \
                -type d -name "temp" -print0 2>/dev/null)
        fi
        if [[ -f "${root}/var/log/emerge.log" ]]; then
            log_files+=("${root}/var/log/emerge.log")
        fi
    done

    if (( ${#log_files[@]} == 0 )); then
        return 0
    fi

    if ! command -v storageto >/dev/null 2>&1; then
        log_warn "storageto not found; skipping failure log upload"
        return 0
    fi

    log_warn "Build failed; gathering Portage failure logs for upload..."
    local archive_name="portage-failure-logs-$(date +%Y%m%d%H%M%S).tar.zst"
    local archive="/tmp/${archive_name}"

    tar --create --file="${archive}" \
        --use-compress-program="zstd --long -9 --threads=0" \
        --directory="/" \
        "${log_files[@]#/}" 2>/dev/null || true

    if [[ -f "${archive}" && -s "${archive}" ]]; then
        upload_to_storageto "${archive}"
        force_remove "${archive}"
    fi
}

register_failure_hook upload_portage_failure_logs

# === Signing & Security ===

import_signing_key() {
    if [[ -v _signing_key_fingerprint ]]; then
        return
    fi

    log_info "Importing PGP signing key"

    _signing_key_fingerprint=$(gpg --show-keys --with-colons \
        <<< "${SIGNING_KEY}" | awk --field-separator=":" '/^fpr/ {print $10}')

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

    printf "%s\n" "BINPKG_GPG_SIGNING_KEY=\"${_signing_key_fingerprint}\"" \
        >> "${target_root}/etc/portage/make.conf"
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

    log_info "Verifying ${seed_tarball}"
    gpg --verify "${seed_tarball}.asc" \
        "${seed_tarball}"

    remove_file "${seed_tarball}.asc"

    log_info "Extracting ${seed_tarball} to ${output_dir}"
    tar --directory="${output_dir}" --extract \
        --file="${seed_tarball}" --numeric-owner \
        --preserve-permissions --xattrs-include='*.*'

    remove_file "${seed_tarball}"
    force_remove "${download_dir}"
}

fetch_project_stage() {
    local target_root="${1}"
    local profile="${2}"
    local stage_type="${3}"
    log_info "Downloading and extracting Gentoo ${stage_type} to ${target_root}"

    import_signing_key

    create_directory "${target_root}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local profile_name="${repo_profile//\//-}"
    local stage_filename="${stage_type}-${profile_name}.tar.zst"
    local sig_filename="${stage_filename}.sig"
    local download_dir
    download_dir="$(mktemp --directory)"
    local stage_file="${download_dir}/${stage_filename}"
    local sig_file="${download_dir}/${sig_filename}"
    log_info "Downloading stage archive ${stage_file}"
    s3_rclone copy ":s3:${S3_BUCKET_NAME}/${stage_filename}" \
        "${download_dir}"

    log_info "Downloading stage archive signature ${sig_file}"
    s3_rclone copy ":s3:${S3_BUCKET_NAME}/${sig_filename}" \
        "${download_dir}"

    log_info "Verifying stage archive ${stage_file}"
    gpg --verify "${sig_file}" "${stage_file}"

    log_info "Extracting stage archive ${stage_file} to ${target_root}"
    tar --directory="${target_root}" --extract --file="${stage_file}" \
        --preserve-permissions --numeric-owner --xattrs-include='*.*' \
        --use-compress-program="zstd --long=31"

    force_remove "${stage_file}"
    force_remove "${sig_file}"
    force_remove "${download_dir}"
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
    tar --create --file="${stage_file}" --directory="${target_root}" \
        --preserve-permissions --numeric-owner --xattrs-include='*.*' \
        --use-compress-program="zstd --long=31 -9 --threads=0" \
        --exclude=".${PORTAGE_GPG_DIR}" \
        --exclude=".${PORTAGE_SECUREBOOT_DIR}" \
        --exclude="./boot/*" \
        --exclude="./etc/kernel" \
        --exclude="./etc/machine-id" \
        --exclude="./etc/resolv.conf" \
        --exclude="./root/*" \
        --exclude="./tmp/*" \
        --exclude="./var/cache/*" \
        --exclude="./var/lib/systemd/catalog/database" \
        --exclude="./var/log/*" \
        --exclude="./var/tmp/*" \
        .
    log_info "Signing stage archive ${stage_file}"
    gpg --batch --detach-sign --local-user "${_signing_key_fingerprint}" \
        "${stage_file}"

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

    local lowerdir="${binpkgs_dir}-lower"
    create_directory "${lowerdir}"
    local upperdir="${binpkgs_dir}-upper"
    create_directory "${upperdir}"
    local workdir="${binpkgs_dir}-work"
    create_directory "${workdir}"

    local rc_sock="${binpkgs_dir}-rc.sock"
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

    local timeout=100
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
