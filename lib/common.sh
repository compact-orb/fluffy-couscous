# Caller scripts declare a required_commands=() array first,
# and then source this file. This += appends these base requirements to the
# caller's array. The caller can then add its own specifics.
required_commands+=(
    "awk"
    "chmod"
    "chroot"
    "cp"
    "cryptsetup"
    "dirname"
    "find"
    "git"
    "gpg"
    "ln"
    "mkdir"
    "mktemp"
    "mount"
    "rclone"
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "tar"
    "udevadm"
    "umount"
    "zstd"
)

readonly _COMMON_SH_INCLUDED=1
readonly WORK_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
env_file="${WORK_DIR}/.env"
if [[ -f "${env_file}" ]]; then
    # Preserve environment variables already set before sourcing .env so
    # caller/CI overrides take precedence over values in the .env file.
    declare -A _preserved_env=()
    for var in \
        GENTOO_MIRROR_URL \
        REPOS \
        BINPKG_REPOS \
        ANSIBLE_PULL_URL \
        SIGNING_KEY \
        BINPKG_PUBLIC_KEY \
        REPO_PUBLIC_KEYS \
        S3_ACCESS_KEY_ID \
        S3_SECRET_ACCESS_KEY \
        S3_RO_SECRET_ACCESS_KEY \
        S3_REGION \
        S3_ENDPOINT \
        S3_BUCKET_NAME \
        SECUREBOOT_KEY \
        SECUREBOOT_CERT \
        STORAGETO_KEY; do
        if [[ -v "${var}" ]]; then
            _preserved_env["${var}"]="${!var}"
        fi
    done

    # shellcheck source=/dev/null
    source "${env_file}"

    for var in "${!_preserved_env[@]}"; do
        printf -v "${var}" "%s" "${_preserved_env[${var}]}"
    done
    unset _preserved_env
fi
unset env_file

# === Logging Helpers ===

log_debug() {
    printf "[DEBUG] %s\n" "${*}"
}

log_info() {
    printf "[INFO] %s\n" "${*}"
}

log_warn() {
    printf "[WARN] %s\n" "${*}" >&2
}

log_error() {
    printf "[ERROR] %s\n" "${*}" >&2
}

# === Command Requirements ===

check_root() {
    if (( EUID != 0 )); then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_required_commands() {
    local missing_commands=()
    local cmd
    local seen_commands=()
    for cmd in "${required_commands[@]}"; do
        local already_seen=0
        local seen
        for seen in "${seen_commands[@]}"; do
            if [[ "${seen}" == "${cmd}" ]]; then
                already_seen=1
                break
            fi
        done
        if (( already_seen )); then
            continue
        fi
        seen_commands+=("${cmd}")
        if ! command -v "${cmd}" > /dev/null 2>&1; then
            missing_commands+=("${cmd}")
        fi
    done
    if (( ${#missing_commands[@]} > 0 )); then
        log_error "Missing required commands: ${missing_commands[*]}"
        exit 1
    fi
}

# === CLI Argument Parsing ===

declare -A _cli_options
declare -A _cli_option_descriptions
declare -A _cli_option_defaults
declare -A _cli_option_patterns
declare -A _cli_flags
declare -A _cli_flag_descriptions
declare -a _cli_flag_patterns

cli_define_option() {
    local var_name="${1}"
    local patterns="${2}"
    local description="${3}"
    local required="${4:-0}"
    local default_value="${5:-}"

    _cli_options["${var_name}"]="${required}"
    _cli_option_descriptions["${var_name}"]="${description}"
    _cli_option_defaults["${var_name}"]="${default_value}"
    _cli_option_patterns["${var_name}"]="${patterns}"
}

cli_define_flag() {
    local var_name="${1}"
    local patterns="${2}"
    local description="${3}"
    local default_value="${4:-0}"

    _cli_flags["${var_name}"]="${default_value}"
    _cli_flag_descriptions["${var_name}"]="${description}"
    _cli_flag_patterns+=("${patterns}:${var_name}")
}

cli_help() {
    printf "Usage: %s [options]\n\n" "${0}"
    printf "Options:\n"
    local var_name pattern default_val desc
    for var_name in "${!_cli_options[@]}"; do
        pattern="${_cli_option_patterns[${var_name}]}"
        pattern="${pattern//|/, }"
        default_val="${_cli_option_defaults[${var_name}]}"
        desc="${_cli_option_descriptions[${var_name}]}"
        if [[ -n "${default_val}" ]]; then
            printf "  %-30s %s (default: %s)\n" \
                "${pattern} <val>" "${desc}" "${default_val}"
        else
            printf "  %-30s %s\n" "${pattern} <val>" "${desc}"
        fi
    done
    local flag_entry flag_pattern
    for flag_entry in "${_cli_flag_patterns[@]}"; do
        flag_pattern="${flag_entry%%:*}"
        var_name="${flag_entry##*:}"
        flag_pattern="${flag_pattern//|/, }"
        desc="${_cli_flag_descriptions[${var_name}]}"
        printf "  %-30s %s\n" "${flag_pattern}" "${desc}"
    done
    printf "  %-30s %s\n" "-h, --help" "Show this help message"
}

cli_parse() {
    local -A opt_lookup=()
    local -A flag_lookup=()
    local var_name patterns p

    for var_name in "${!_cli_option_patterns[@]}"; do
        patterns="${_cli_option_patterns[${var_name}]}"
        while [[ "${patterns}" =~ ([^|]+) ]]; do
            opt_lookup["${BASH_REMATCH[1]}"]="${var_name}"
            patterns="${patterns#*"${BASH_REMATCH[1]}"}"
            patterns="${patterns#|}"
        done
    done

    local flag_entry flag_pattern
    for flag_entry in "${_cli_flag_patterns[@]}"; do
        flag_pattern="${flag_entry%%:*}"
        var_name="${flag_entry##*:}"
        while [[ "${flag_pattern}" =~ ([^|]+) ]]; do
            flag_lookup["${BASH_REMATCH[1]}"]="${var_name}"
            flag_pattern="${flag_pattern#*"${BASH_REMATCH[1]}"}"
            flag_pattern="${flag_pattern#|}"
        done
    done

    for var_name in "${!_cli_options[@]}"; do
        printf -v "${var_name}" "%s" "${_cli_option_defaults[${var_name}]}"
    done

    for var_name in "${!_cli_flags[@]}"; do
        printf -v "${var_name}" "%s" "${_cli_flags[${var_name}]}"
    done

    while (( ${#} > 0 )); do
        case "${1}" in
            -h|--help)
                cli_help
                exit 0
                ;;
            *)
                local matched=0
                if [[ -n "${opt_lookup[${1}]:-}" ]]; then
                    var_name="${opt_lookup[${1}]}"
                    if (( ${#} < 2 )); then
                        log_error "Option ${1} requires an argument."
                        cli_help
                        exit 1
                    fi
                    printf -v "${var_name}" "%s" "${2}"
                    shift 2
                    matched=1
                    continue
                fi

                for p in "${!opt_lookup[@]}"; do
                    if [[ "${1}" == "${p}="* ]]; then
                        var_name="${opt_lookup[${p}]}"
                        printf -v "${var_name}" "%s" "${1#*=}"
                        shift
                        matched=1
                        break
                    fi
                done
                if (( matched )); then
                    continue
                fi

                if [[ -n "${flag_lookup[${1}]:-}" ]]; then
                    var_name="${flag_lookup[${1}]}"
                    printf -v "${var_name}" "1"
                    shift
                    matched=1
                    continue
                fi

                log_error "Unknown argument: ${1}"
                cli_help
                exit 1
                ;;
        esac
    done

    local missing_required=0
    for var_name in "${!_cli_options[@]}"; do
        if (( _cli_options["${var_name}"] )) && \
            [[ -z "${!var_name}" ]]; then
            log_error "Missing required option: ${_cli_option_patterns[${var_name}]}"
            missing_required=1
        fi
    done

    if (( missing_required )); then
        cli_help
        exit 1
    fi
}

parse_profile() {
    local profile="${1}"
    if [[ "${profile}" =~ ^([a-zA-Z0-9_-]+):([a-zA-Z0-9_/-]+)$ ]]; then
        printf "%s %s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        log_error "Invalid profile format: ${profile} (expected repo:profile)"
        return 1
    fi
}

# === File and Directory Helpers ===

# Base build directory. Cleaned up on script exit via the EXIT trap when set.
readonly BUILD_DIR="$(mktemp --directory)"
chmod 0755 "${BUILD_DIR}"

managed_build_dir_cleanup() {
    local exit_code="${?}"
    if [[ -d "${BUILD_DIR}" ]]; then
        log_debug "Removing build directory ${BUILD_DIR}"
        rm -rf "${BUILD_DIR}"
    fi
    exit "${exit_code}"
}
trap managed_build_dir_cleanup "EXIT"

create_directory() {
    local dir="${1}"
    if [[ ! -d "${dir}" ]]; then
        log_debug "Creating directory ${dir}"
        mkdir --parents "${dir}"
    fi
}

remove_directory() {
    local dir="${1}"
    if [[ -d "${dir}" ]]; then
        log_debug "Removing directory ${dir}"
        rmdir "${dir}"
    fi
}

create_file() {
    local file="${1}"
    local content="${2:-}"
    log_debug "Creating file ${file}"
    printf "%s\n" "${content}" > "${file}"
}

create_empty_file() {
    local file="${1}"
    log_debug "Creating empty file ${file}"
    : > "${file}"
}

copy_file() {
    local src="${1}"
    local dst="${2}"
    log_debug "Copying ${src} to ${dst}"
    cp "${src}" "${dst}"
}

force_remove() {
    local path="${1}"
    if [[ -e "${path}" ]]; then
        log_debug "Force removing ${path}"
        rm -rf "${path}"
    fi
}

create_symlink() {
    local target="${1}"
    local link_name="${2}"
    log_debug "Creating symlink ${link_name} -> ${target}"
    ln -sf "${target}" "${link_name}"
}

# === Archive Helpers ===

tar_create() {
    local archive="${1}"
    local src_dir="${2}"
    shift 2

    log_debug "Creating tar archive ${archive} from ${src_dir}"
    tar --create \
        --directory="${src_dir}" \
        --file="${archive}" \
        --numeric-owner \
        --use-compress-program="zstd -19 --threads=0" \
        "${@}"
}

tar_extract() {
    local archive="${1}"
    local dst_dir="${2}"
    shift 2

    log_debug "Extracting tar archive ${archive} to ${dst_dir}"
    tar --extract \
        --directory="${dst_dir}" \
        --file="${archive}" \
        --numeric-owner \
        --use-compress-program="zstd -d" \
        "${@}"
}

tar_append() {
    local archive="${1}"
    local src_dir="${2}"
    shift 2

    log_debug "Appending to tar archive ${archive} from ${src_dir}"
    tar --append \
        --directory="${src_dir}" \
        --file="${archive}" \
        --numeric-owner \
        "${@}"
}

# === Configuration Parsing ===

parse_env_list() {
    local content="${1}"
    local -a result=()
    local line
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -n "${line}" && ! "${line}" =~ ^# ]]; then
            result+=("${line}")
        fi
    done <<< "${content}"
    printf "%s\n" "${result[@]}"
}

# === Mount Management ===

_registered_mount_arrays=()

register_mount_array() {
    local array_name="${1}"
    local existing
    for existing in "${_registered_mount_arrays[@]}"; do
        if [[ "${existing}" == "${array_name}" ]]; then
            return 0
        fi
    done
    _registered_mount_arrays+=("${array_name}")
}

managed_mount() {
    local array_name="${1}"
    register_mount_array "${array_name}"
    declare -n mount_ref="${array_name}"
    shift

    local target="${*: -1}"
    log_debug "Mounting ${target}"
    mount "${@}"
    mount_ref+=("${target}")
}

managed_unmount() {
    local array_name="${1}"
    declare -n mount_ref="${array_name}"
    local target="${2}"

    if findmnt --mountpoint "${target}" > /dev/null 2>&1; then
        log_debug "Unmounting ${target}"
        umount --recursive "${target}"
    fi

    local remaining_mounts=()
    local m
    for m in "${mount_ref[@]}"; do
        if [[ "${m}" != "${target}" ]]; then
            remaining_mounts+=("${m}")
        fi
    done
    mount_ref=("${remaining_mounts[@]}")
}

managed_unmount_all() {
    local array_name="${1}"
    declare -n mount_ref="${array_name}"

    local i
    for (( i=${#mount_ref[@]}-1; i>=0; i-- )); do
        local target="${mount_ref[$i]}"
        if findmnt --mountpoint "${target}" > /dev/null 2>&1; then
            log_debug "Unmounting ${target}"
            umount --recursive "${target}"
        fi
    done
    mount_ref=()
}

# === Cryptsetup Management ===

_active_crypt_devices=()

managed_cryptsetup() {
    local action="${1}"
    shift

    case "${action}" in
        open)
            local mapper_name="${*: -1}"
            log_debug "Opening encrypted device ${mapper_name}"
            cryptsetup open "${@}"
            _active_crypt_devices+=("${mapper_name}")
            ;;
        close)
            local mapper_name="${1}"
            if [[ -b "/dev/mapper/${mapper_name}" ]]; then
                log_debug "Closing encrypted device ${mapper_name}"
                udevadm settle
                cryptsetup close "${mapper_name}"
            fi
            local remaining_devices=()
            local dev
            for dev in "${_active_crypt_devices[@]}"; do
                if [[ "${dev}" != "${mapper_name}" ]]; then
                    remaining_devices+=("${dev}")
                fi
            done
            _active_crypt_devices=("${remaining_devices[@]}")
            ;;
        *)
            cryptsetup "${action}" "${@}"
            ;;
    esac
}

managed_cryptsetup_close_all() {
    local i
    for (( i=${#_active_crypt_devices[@]}-1; i>=0; i-- )); do
        local dev="${_active_crypt_devices[$i]}"
        if [[ -b "/dev/mapper/${dev}" ]]; then
            log_debug "Closing encrypted device ${dev}"
            udevadm settle
            cryptsetup close "${dev}" || true
        fi
    done
    _active_crypt_devices=()
}

# === Loop Device Management ===

_active_loop_devices=()

managed_losetup() {
    local action="${1}"
    case "${action}" in
        attach)
            local file="${2}"
            local loop_dev
            loop_dev="$(losetup --find --partscan --show "${file}")"
            _active_loop_devices+=("${loop_dev}")
            printf "%s\n" "${loop_dev}"
            ;;
        detach)
            local loop_dev="${2}"
            if [[ -b "${loop_dev}" ]]; then
                log_debug "Detaching loop device ${loop_dev}"
                udevadm settle
                losetup --detach "${loop_dev}" 2> /dev/null || true
            fi
            local -a remaining_devices=()
            local dev
            for dev in "${_active_loop_devices[@]}"; do
                if [[ "${dev}" != "${loop_dev}" ]]; then
                    remaining_devices+=("${dev}")
                fi
            done
            _active_loop_devices=("${remaining_devices[@]}")
            ;;
        *)
            losetup "${action}" "${@}"
            ;;
    esac
}

managed_losetup_detach_all() {
    local i
    for (( i=${#_active_loop_devices[@]}-1; i>=0; i-- )); do
        local dev="${_active_loop_devices[$i]}"
        if [[ -b "${dev}" ]]; then
            log_debug "Detaching loop device ${dev}"
            udevadm settle
            losetup --detach "${dev}" 2> /dev/null || true
        fi
    done
    _active_loop_devices=()
}

_failure_hooks=()
register_failure_hook() {
    _failure_hooks+=("${1}")
}

managed_cleanup_all() {
    local exit_code="${?}"
    # Run failure hooks before unmounting so chroot build logs are still
    # accessible on disk when a build fails.
    if (( exit_code != 0 )); then
        local hook
        for hook in "${_failure_hooks[@]}"; do
            "${hook}" "${exit_code}" || true
        done
    fi
    local i
    for (( i=${#_registered_mount_arrays[@]}-1; i>=0; i-- )); do
        managed_unmount_all "${_registered_mount_arrays[$i]}" || true
    done
    managed_cryptsetup_close_all
    managed_losetup_detach_all
    exit "${exit_code}"
}
trap managed_cleanup_all "EXIT"

# === Ebuild Repositories ===

_repo_entries=()
load_ebuild_repositories() {
    if [[ -v _ebuild_repositories_loaded ]]; then
        return
    fi

    local repo_entry
    while IFS= read -r repo_entry || [[ -n "${repo_entry}" ]]; do
        if [[ -n "${repo_entry}" ]]; then
            _repo_entries+=("${repo_entry}")
        fi
    done < <(parse_env_list "${REPOS:-}")

    _ebuild_repositories_loaded=1
}

readonly LOCAL_REPOS_DIR="${BUILD_DIR}/repos"

download_ebuild_repositories() {
    local target_root="${1}"
    log_info "Downloading ebuild repositories to ${LOCAL_REPOS_DIR}"

    load_ebuild_repositories

    create_directory "${LOCAL_REPOS_DIR}"

    local repo_entry repo_name repo_url repo_branch
    for repo_entry in "${_repo_entries[@]}"; do
        read -r repo_name repo_url repo_branch <<< "${repo_entry}"
        local repo_dir="${LOCAL_REPOS_DIR}/${repo_name}"

        if [[ ! -d "${repo_dir}/.git" ]]; then
            log_info "Cloning repository ${repo_name} from ${repo_url}"
            local clone_args=(
                "--filter=blob:none"
                "--no-checkout"
            )
            if [[ -n "${repo_branch}" ]]; then
                clone_args+=("--branch=${repo_branch}")
            fi
            git clone "${clone_args[@]}" "${repo_url}" "${repo_dir}"
        fi

        log_info "Verifying HEAD commit signature of ${repo_name}"
        git -C "${repo_dir}" verify-commit "HEAD"
        git -C "${repo_dir}" checkout --detach "HEAD"
    done
}

configure_ebuild_repositories() {
    local target_root="${1}"
    log_info "Configuring ebuild repositories in ${target_root}"

    load_ebuild_repositories

    local repos_conf_dir="${target_root}/etc/portage/repos.conf"
    create_directory "${repos_conf_dir}"

    local gentoo_repo_conf="${repos_conf_dir}/gentoo.conf"
    local gentoo_sync_uri="${GENTOO_MIRROR_URL:-rsync://rsync.gentoo.org/gentoo-portage}"

    log_debug "Creating ${gentoo_repo_conf}"
    cat << EOF > "${gentoo_repo_conf}"
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = ${gentoo_sync_uri}
auto-sync = yes
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age = 24
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
sync-openpgp-keyserver = hkps://keys.gentoo.org
sync-openpgp-key-refresh-retry-count = 40
sync-openpgp-key-refresh-retry-overall-timeout = 1200
sync-openpgp-key-refresh-retry-delay-exp-base = 2
sync-openpgp-key-refresh-retry-delay-max = 60
sync-openpgp-key-refresh-retry-delay-mult = 4
EOF

    local repo_entry repo_name repo_url repo_branch
    for repo_entry in "${_repo_entries[@]}"; do
        read -r repo_name repo_url repo_branch <<< "${repo_entry}"
        local repo_conf="${repos_conf_dir}/${repo_name}.conf"
        log_debug "Creating ${repo_conf}"
        cat << EOF > "${repo_conf}"
[${repo_name}]
location = /var/db/repos/${repo_name}
sync-type = git
sync-uri = ${repo_url}
auto-sync = yes
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /etc/portage/gnupg
EOF
    done
}

_active_repo_mounts=()

mount_repos() {
    local target_root="${1}"
    log_info "Mounting ebuild repositories into ${target_root}"

    load_ebuild_repositories

    download_ebuild_repositories "${target_root}"

    local target_repos_dir="${target_root}/var/db/repos"
    create_directory "${target_repos_dir}"

    local repo_entry repo_name
    for repo_entry in "${_repo_entries[@]}"; do
        repo_name="${repo_entry%% *}"
        local repo_dir="${LOCAL_REPOS_DIR}/${repo_name}"
        local target_repo_dir="${target_repos_dir}/${repo_name}"

        create_directory "${target_repo_dir}"
        managed_mount "_active_repo_mounts" --bind "${repo_dir}" \
            "${target_repo_dir}"
    done
}

unmount_repos() {
    log_info "Unmounting ebuild repositories"
    managed_unmount_all "_active_repo_mounts"
}

# === GPG and Security ===

_signing_key_fingerprint=""

import_signing_key() {
    if [[ -n "${_signing_key_fingerprint}" ]]; then
        return
    fi

    if [[ -z "${SIGNING_KEY:-}" ]]; then
        log_error "SIGNING_KEY environment variable is not set."
        exit 1
    fi

    log_info "Importing repository signing key into host GPG keyring"

    local import_output
    import_output="$(gpg --batch --import <<< "${SIGNING_KEY}" 2>&1)"

    # Prefer a secret subkey with signing capability ([s]), falling back to the
    # primary secret key ([u]).
    local fingerprint
    fingerprint="$(gpg --batch --with-colons --list-secret-keys 2> /dev/null | \
        awk -F: '
            $1 == "sec" { primary = "" }
            $1 == "fpr" && primary == "" { primary = $10 }
            $1 == "ssb" && $12 ~ /s/ { subkey = ""; next }
            $1 == "fpr" && subkey == "" { print $10; exit }
            END { if (primary != "") print primary }
        ')"

    if [[ -z "${fingerprint}" ]]; then
        log_error "Failed to retrieve fingerprint of imported SIGNING_KEY."
        log_error "${import_output}"
        exit 1
    fi

    log_info "Using signing key with fingerprint: ${fingerprint}"
    _signing_key_fingerprint="${fingerprint}"
}

import_bundled_keys() {
    local bundled_key_file="${WORK_DIR}/etc/gentoo-release.asc"
    if [[ -f "${bundled_key_file}" ]]; then
        log_info "Importing bundled Gentoo release keys from ${bundled_key_file}"
        gpg --import --quiet "${bundled_key_file}"
    else
        log_warn "Bundled release keys not found at ${bundled_key_file}"
    fi
}

import_public_keys() {
    local all_keys=""
    if [[ -n "${REPO_PUBLIC_KEYS:-}" ]]; then
        all_keys+="${REPO_PUBLIC_KEYS}"$'\n'
    fi
    if [[ -n "${BINPKG_PUBLIC_KEY:-}" ]]; then
        all_keys+="${BINPKG_PUBLIC_KEY}"$'\n'
    fi
    if [[ -n "${SEED_PUBLIC_KEYS:-}" ]]; then
        all_keys+="${SEED_PUBLIC_KEYS}"$'\n'
    fi

    if [[ -n "${all_keys//[[:space:]]/}" ]]; then
        gpg --import --quiet <<< "${all_keys}"
    fi
}

# === S3 & Stage Archives ===

s3_rclone() {
    local cmd="${1}"
    shift

    local secret_key="${S3_SECRET_ACCESS_KEY:-}"
    if [[ -z "${secret_key}" ]]; then
        secret_key="${S3_RO_SECRET_ACCESS_KEY:-}"
    fi

    local -a env_args=(
        "RCLONE_CONFIG_S3_TYPE=s3"
        "RCLONE_CONFIG_S3_PROVIDER=Other"
        "RCLONE_CONFIG_S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}"
        "RCLONE_CONFIG_S3_SECRET_ACCESS_KEY=${secret_key}"
        "RCLONE_CONFIG_S3_REGION=${S3_REGION}"
        "RCLONE_CONFIG_S3_ENDPOINT=${S3_ENDPOINT}"
    )

    env "${env_args[@]}" rclone "${cmd}" --s3-no-check-bucket "${@}"
}

fetch_seed_stage() {
    local target_root="${1}"
    local arch="${2}"
    local name="${3}"
    log_info "Fetching seed stage for ${arch}/${name} into ${target_root}"

    local stage_url="${GENTOO_MIRROR_URL:-https://distfiles.gentoo.org}/releases/${arch}/autobuilds/current-${name}/"
    local stage_dir="${BUILD_DIR}/stage"
    create_directory "${stage_dir}"

    local latest_txt_url="${stage_url}latest-${name}.txt"
    local latest_txt="${stage_dir}/latest-${name}.txt"
    rclone copyto "${latest_txt_url}" "${latest_txt}"

    import_bundled_keys
    gpg --verify "${latest_txt}"

    local tarball_path
    tarball_path="$(awk '!/^#/ && NF {print $1; exit}' "${latest_txt}")"
    local tarball_filename="${tarball_path##*/}"

    local tarball_url="${GENTOO_MIRROR_URL:-https://distfiles.gentoo.org}/releases/${arch}/autobuilds/${tarball_path}"
    local tarball_file="${stage_dir}/${tarball_filename}"
    local dsig_url="${tarball_url}.asc"
    local dsig_file="${stage_dir}/${tarball_filename}.asc"

    rclone copyto "${tarball_url}" "${tarball_file}"
    rclone copyto "${dsig_url}" "${dsig_file}"

    gpg --verify "${dsig_file}" "${tarball_file}"

    create_directory "${target_root}"
    tar_extract "${tarball_file}" "${target_root}"
    force_remove "${stage_dir}"
}

fetch_project_stage() {
    local target_root="${1}"
    local profile="${2}"
    local stage_type="${3}"
    log_info "Downloading and extracting Gentoo ${stage_type} to ${target_root}"

    import_bundled_keys
    import_public_keys

    if [[ -n "${SIGNING_KEY:-}" ]] && \
        declare -F import_signing_key > /dev/null; then
        import_signing_key
    fi

    create_directory "${target_root}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")
    local profile_name="${repo_profile//\//-}"
    local stage_filename="${stage_type}-${profile_name}.tar.zst"
    local sig_filename="${stage_filename}.sig"

    local temp_dir="${BUILD_DIR}/stage"
    create_directory "${temp_dir}"

    local stage_file="${temp_dir}/${stage_filename}"
    local sig_file="${temp_dir}/${sig_filename}"

    log_info "Downloading ${stage_filename} from S3"
    s3_rclone copyto ":s3:${S3_BUCKET_NAME}/${stage_filename}" "${stage_file}"
    log_info "Downloading ${sig_filename} from S3"
    s3_rclone copyto ":s3:${S3_BUCKET_NAME}/${sig_filename}" "${sig_file}"

    log_info "Verifying signature for ${stage_filename}"
    gpg --batch --verify "${sig_file}" "${stage_file}"

    tar_extract "${stage_file}" "${target_root}"

    force_remove "${temp_dir}"
}

# === Portage Configuration ===

remove_portage_configuration() {
    local target_root="${1}"
    local portage_dir="${target_root}/etc/portage"
    log_info "Removing portage configuration from ${portage_dir}"
    force_remove "${portage_dir}"
}

configure_portage_profile() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Configuring portage profile ${profile} in ${target_root}"

    local portage_conf_dir="${target_root}/etc/portage"
    create_directory "${portage_conf_dir}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local profile_dir=\
"${target_root}/var/db/repos/${repo}/profiles/${repo_profile}"
    if [[ -d "${target_root}/var/db/repos/${repo}" && \
        ! -d "${profile_dir}" ]]; then
        log_error \
            "Profile '${repo_profile}' not found in repository '${repo}'"
        return 1
    fi

    local portage_conf_profile_dir="${portage_conf_dir}/make.profile"
    local relative_repo_profile_dir=\
"../../var/db/repos/${repo}/profiles/${repo_profile}"

    create_symlink "${relative_repo_profile_dir}" "${portage_conf_profile_dir}"
}

readonly PORTAGE_GPG_DIR="/etc/portage/gnupg"
readonly PORTAGE_SECUREBOOT_DIR="/etc/kernel/certs"

configure_portage() {
    local target_root="${1}"
    local profile="${2}"
    local context="${3}"
    log_info "Configuring portage in ${target_root} for profile ${profile}"

    configure_portage_profile "${target_root}" "${profile}"

    configure_ebuild_repositories "${target_root}"

    # Bootstrap contexts build with local toolchain flags and must omit
    # binhost configs so packages are built from source with target USE flags.
    if [[ "${context}" != "stage1" && "${context}" != "stage3" ]]; then
        configure_portage_binary_packages "${target_root}" "${profile}"
    fi

    # Set up Portage's standalone GPG keyring for repository signature
    # verification during emaint sync and git verification.
    local portage_gnupg_dir="${target_root}${PORTAGE_GPG_DIR}"
    create_directory "${portage_gnupg_dir}"
    chmod 0755 "${portage_gnupg_dir}"

    import_public_keys
    gpg --export | gpg --homedir "${portage_gnupg_dir}" --import

    local ownertrust_entries=()
    local key_id
    while IFS= read -r key_id || [[ -n "${key_id}" ]]; do
        if [[ -n "${key_id}" ]]; then
            ownertrust_entries+=("${key_id}:6:")
        fi
    done < <(gpg --homedir "${portage_gnupg_dir}" --list-keys \
        --with-colons 2> /dev/null | awk -F: '$1 == "pub" { print $5 }')

    if (( ${#ownertrust_entries[@]} > 0 )); then
        printf "%s\n" "${ownertrust_entries[@]}" | \
            gpg --homedir "${portage_gnupg_dir}" --import-ownertrust
    fi

    # Portage drops root privileges to the portage user during signature
    # verification, so trustdb.gpg must be world-readable.
    chmod ugo+r "${portage_gnupg_dir}/trustdb.gpg" 2> /dev/null || true
    gpgconf --homedir "${portage_gnupg_dir}" --kill all 2> /dev/null || true

    # Mask check-chroot plugin to allow kernel-install in chroot
    create_directory "${target_root}/etc/kernel/install.d"
    create_symlink "/dev/null" \
        "${target_root}/etc/kernel/install.d/50-check-chroot.install"

    # Mask unified kernel image generation plugins
    create_symlink "/dev/null" \
        "${target_root}/etc/kernel/install.d/60-ukify.install"
    create_symlink "/dev/null" \
        "${target_root}/etc/kernel/install.d/92-systemd-boot-uki.install"

    # Install Secure Boot signing keys and enrollment certificate for dracut
    # module signing and UEFI validation.
    if [[ -n "${SECUREBOOT_KEY:-}" ]]; then
        local kernel_certs_dir="${target_root}${PORTAGE_SECUREBOOT_DIR}"
        create_directory "${kernel_certs_dir}"
        chmod 0700 "${kernel_certs_dir}"

        create_file "${kernel_certs_dir}/secureboot.key" "${SECUREBOOT_KEY}"
        chmod 0600 "${kernel_certs_dir}/secureboot.key"

        create_file "${kernel_certs_dir}/secureboot.crt" "${SECUREBOOT_CERT}"
        chmod 0644 "${kernel_certs_dir}/secureboot.crt"

        create_directory "${target_root}/etc/kernel"
        create_file "${target_root}/etc/kernel/install.conf" \
            "secureboot_key=\"${PORTAGE_SECUREBOOT_DIR}/secureboot.key\"
secureboot_certificate=\"${PORTAGE_SECUREBOOT_DIR}/secureboot.crt\""
    fi
}

configure_portage_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Configuring binary packages in ${target_root}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local binrepos_conf_dir="${target_root}/etc/portage/binrepos.conf"
    create_directory "${binrepos_conf_dir}"

    local default_binrepo_conf="${binrepos_conf_dir}/default.conf"
    local default_binrepo_name="${repo_profile//\//-}"
    local default_binrepo_url="${S3_ENDPOINT}/${S3_BUCKET_NAME}/binpkgs/${repo_profile}"

    log_debug "Creating ${default_binrepo_conf}"
    cat << EOF > "${default_binrepo_conf}"
[${default_binrepo_name}]
sync-uri = ${default_binrepo_url}
priority = 1
EOF

    local binpkg_repo_entries=()
    local binpkg_repo_entry
    while IFS= read -r binpkg_repo_entry || [[ -n "${binpkg_repo_entry}" ]]; do
        if [[ -n "${binpkg_repo_entry}" ]]; then
            binpkg_repo_entries+=("${binpkg_repo_entry}")
        fi
    done < <(parse_env_list "${BINPKG_REPOS:-}")

    local binpkg_repo_name binpkg_repo_url binpkg_repo_priority
    for binpkg_repo_entry in "${binpkg_repo_entries[@]}"; do
        read -r binpkg_repo_name binpkg_repo_url binpkg_repo_priority \
            <<< "${binpkg_repo_entry}"
        local binrepo_conf="${binrepos_conf_dir}/${binpkg_repo_name}.conf"
        log_debug "Creating ${binrepo_conf}"
        cat << EOF > "${binrepo_conf}"
[${binpkg_repo_name}]
sync-uri = ${binpkg_repo_url}
priority = ${binpkg_repo_priority}
EOF
    done
}

# === Chroot Environment ===

_active_chroot_mounts=()

mount_chroot_filesystems() {
    local target_root="${1}"
    log_info "Mounting chroot filesystems for ${target_root}"

    create_directory "${target_root}/etc"
    if [[ ! -L "${target_root}/etc/resolv.conf" ]]; then
        copy_file "/etc/resolv.conf" "${target_root}/etc/resolv.conf"
    fi

    create_directory "${target_root}/proc"
    managed_mount "_active_chroot_mounts" --types "proc" "/proc" \
        "${target_root}/proc"

    create_directory "${target_root}/sys"
    managed_mount "_active_chroot_mounts" --rbind "/sys" "${target_root}/sys"
    managed_mount "_active_chroot_mounts" --make-rslave "${target_root}/sys"

    create_directory "${target_root}/run"
    managed_mount "_active_chroot_mounts" --bind "/run" "${target_root}/run"
    managed_mount "_active_chroot_mounts" --make-slave "${target_root}/run"

    create_directory "${target_root}/dev"
    managed_mount "_active_chroot_mounts" --rbind "/dev" "${target_root}/dev"
    managed_mount "_active_chroot_mounts" --make-rslave "${target_root}/dev"

    create_directory "${target_root}/dev/shm"
    managed_mount "_active_chroot_mounts" --types "tmpfs" \
        --options "nosuid,nodev,noexec" "shm" "${target_root}/dev/shm"
}

unmount_chroot_filesystems() {
    log_info "Unmounting chroot filesystems"
    managed_unmount_all "_active_chroot_mounts"
}

# Kills lingering background processes that would otherwise keep chroot
# mounts busy during unmount.
is_chroot_process() {
    local proc_dir="${1}"
    local target_root="${2}"

    if [[ ! -d "${proc_dir}" ]]; then
        return 1
    fi
    if [[ "${proc_dir}/root" -ef "${target_root}" ]]; then
        return 0
    fi
    local root_link
    if root_link="$(readlink "${proc_dir}/root" 2> /dev/null)"; then
        if [[ "${root_link}" == "${target_root}" || \
            "${root_link}" == "${target_root}/"* ]]; then
            return 0
        fi
    fi
    return 1
}

kill_chroot_processes() {
    local target_root
    target_root="$(realpath "${1}")"
    if [[ ! -d "${target_root}" ]]; then
        return 0
    fi

    local -a pids=()
    local p
    for p in /proc/[0-9]*; do
        if is_chroot_process "${p}" "${target_root}"; then
            pids+=("${p##*/}")
        fi
    done

    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    log_warn "Killing ${#pids[@]} lingering process(es) in chroot ${target_root}"
    local pid exe
    for pid in "${pids[@]}"; do
        exe="$(basename "$(readlink "/proc/${pid}/exe" 2> /dev/null)" \
            2> /dev/null || true)"
        log_warn "Sending SIGTERM to lingering chroot process ${pid} (${exe:-unknown})"
        kill -s "TERM" "${pid}" 2> /dev/null || true
    done

    local iteration
    for (( iteration=0; iteration<5; iteration++ )); do
        sleep 1
        local has_lingering=0
        for p in /proc/[0-9]*; do
            if is_chroot_process "${p}" "${target_root}"; then
                has_lingering=1
                break
            fi
        done
        if (( has_lingering == 0 )); then
            return 0
        fi
    done

    log_warn "Lingering chroot processes did not exit; sending SIGKILL"
    for p in /proc/[0-9]*; do
        if is_chroot_process "${p}" "${target_root}"; then
            pid="${p##*/}"
            exe="$(basename "$(readlink "/proc/${pid}/exe" 2> /dev/null)" \
                2> /dev/null || true)"
            log_warn "Sending SIGKILL to lingering chroot process" \
                "${pid} (${exe:-unknown})"
            kill -s "KILL" "${pid}" 2> /dev/null || true
        fi
    done

    for (( iteration=0; iteration<10; iteration++ )); do
        sleep 0.5
        local has_lingering=0
        for p in /proc/[0-9]*; do
            if is_chroot_process "${p}" "${target_root}"; then
                has_lingering=1
                break
            fi
        done
        if (( has_lingering == 0 )); then
            return 0
        fi
    done

    log_warn "Some chroot processes could not be killed in ${target_root}"
    return 1
}

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
    create_directory "${target_root}/dev"
    create_directory "${target_root}/dev/pts"
    create_directory "${target_root}/dev/shm"
    chmod 1777 "${target_root}/dev/shm"
    create_directory "${target_root}/var/cache/binpkgs"
    create_directory "${target_root}/var/tmp"
    create_directory "${target_root}/.oldroot"

    [[ -c "${target_root}/dev/null" ]] || \
        mknod -m 0666 "${target_root}/dev/null" c 1 3
    [[ -c "${target_root}/dev/zero" ]] || \
        mknod -m 0666 "${target_root}/dev/zero" c 1 5
    [[ -c "${target_root}/dev/full" ]] || \
        mknod -m 0666 "${target_root}/dev/full" c 1 7
    [[ -c "${target_root}/dev/random" ]] || \
        mknod -m 0666 "${target_root}/dev/random" c 1 8
    [[ -c "${target_root}/dev/urandom" ]] || \
        mknod -m 0666 "${target_root}/dev/urandom" c 1 9
    [[ -c "${target_root}/dev/tty" ]] || \
        mknod -m 0666 "${target_root}/dev/tty" c 5 0

    [[ -L "${target_root}/dev/fd" ]] || \
        ln -sf "/proc/self/fd" "${target_root}/dev/fd"
    [[ -L "${target_root}/dev/stdin" ]] || \
        ln -sf "/proc/self/fd/0" "${target_root}/dev/stdin"
    [[ -L "${target_root}/dev/stdout" ]] || \
        ln -sf "/proc/self/fd/1" "${target_root}/dev/stdout"
    [[ -L "${target_root}/dev/stderr" ]] || \
        ln -sf "/proc/self/fd/2" "${target_root}/dev/stderr"

    [[ -L "${target_root}/dev/ptmx" ]] || \
        ln -sf "pts/ptmx" "${target_root}/dev/ptmx"
}

chroot_run_criu() {
    local target_root="${1}"
    local cmd="${2}"

    local real_target_root
    real_target_root="$(realpath "${target_root}")"

    local criu_dir="${real_target_root}/.criu"
    local is_resuming=0
    if [[ -d "${criu_dir}" ]]; then
        is_resuming=1
        log_info "Found existing CRIU checkpoint in ${real_target_root}"
    fi

    local timeout_sec=0
    if [[ -v CHROOT_TIMEOUT && -n "${CHROOT_TIMEOUT}" ]]; then
        timeout_sec="$(parse_duration_seconds "${CHROOT_TIMEOUT}")"
    fi

    log_info "Executing CRIU-managed namespace in ${real_target_root}" \
        "(timeout: ${timeout_sec}s, resuming: ${is_resuming})"

    prepare_criu_chroot_filesystem "${real_target_root}"

    local status_pipe="${BUILD_DIR}/criu_status.pipe"
    rm -f "${status_pipe}"
    mkfifo "${status_pipe}"

    # Generate a script that configures mounts and either launches a fresh
    # build or restores a CRIU checkpoint.
    local inner_runner="${BUILD_DIR}/criu_inner_runner.sh"
    cat << 'EOF' > "${inner_runner}"
#!/usr/bin/env bash
set -e
target_root="${1}"
status_pipe="${2}"
is_resuming="${3}"
cmd="${4}"

# Make mount hierarchy rprivate to satisfy pivot_root requirements
mount --make-rprivate /

# Bind-mount target_root to itself to ensure it is a mount point
mount --bind "${target_root}" "${target_root}"

mount -t proc proc "${target_root}/proc"
mount -t sysfs sysfs "${target_root}/sys"
mount -t devtmpfs udev "${target_root}/dev"
mount -t devpts devpts "${target_root}/dev/pts" -o gid=5,mode=620
mount -t tmpfs shm "${target_root}/dev/shm" -o nosuid,nodev,noexec
mount -t tmpfs run "${target_root}/run" -o nosuid,nodev,mode=755
mkdir -p "${target_root}/run/lock"
chmod 1777 "${target_root}/run/lock"

cd "${target_root}"
pivot_root . .oldroot

umount -l /.oldroot

mkdir -p /var/tmp
export HOME="/root"
export TERM="${TERM:-dumb}"
export LC_ALL="C.UTF-8"
export LANG="C.UTF-8"
export PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"

if (( is_resuming )); then
    echo "READY_FOR_RESTORE" > "${status_pipe}"
    exec tail -f /dev/null
else
    echo "READY_FOR_RUN" > "${status_pipe}"
    exec /bin/bash --login -e -c "${cmd}"
fi
EOF
    chmod +x "${inner_runner}"

    local runner_log="${BUILD_DIR}/chroot_runner.log"
    local chroot_log="${real_target_root}/var/tmp/.fluffy-chroot.log"
    create_directory "${real_target_root}/var/tmp"

    local unshare_pid
    unshare --mount --pid --fork \
        "${inner_runner}" "${real_target_root}" "${status_pipe}" \
        "${is_resuming}" "${cmd}" > "${runner_log}" 2>&1 &
    unshare_pid="${!}"

    local ready_status
    read -r ready_status < "${status_pipe}"
    rm -f "${status_pipe}"

    local init_pid
    init_pid="$(pgrep -P "${unshare_pid}" | head -n 1)"
    if [[ -z "${init_pid}" ]]; then
        log_error "Failed to locate PID namespace init inside unshare"
        wait "${unshare_pid}" || true
        return 1
    fi

    log_info "Namespace initialized (unshare: ${unshare_pid}, init: ${init_pid})"

    local exit_code=0
    if (( is_resuming )); then
        log_info "Restoring live process tree from CRIU checkpoint"
        local restore_log="${criu_dir}/restore.log"
        local criu_restore_cmd=(
            "criu" "restore"
            "--images-dir" "${criu_dir}"
            "--work-dir" "${criu_dir}"
            "--shell-job"
            "--tcp-established"
            "--file-locks"
            "--link-remap"
            "--log-file" "${restore_log}"
            "--verbose=4"
            "--root" "${real_target_root}"
            "--pidfile" "${criu_dir}/criu_restore.pid"
        )
        # Restore into the PID and mount namespaces of init_pid
        nsenter --target "${init_pid}" --mount --pid \
            "${criu_restore_cmd[@]}" >> "${runner_log}" 2>&1 || exit_code="${?}"

        if (( exit_code != 0 )); then
            log_error "CRIU restore failed with code ${exit_code}."
            if [[ -f "${restore_log}" ]]; then
                tail -n 100 "${restore_log}" >&2 || true
            fi
            kill -9 "${unshare_pid}" 2> /dev/null || true
            return "${exit_code}"
        fi
        log_info "CRIU restore succeeded; resumed process tree active"
        force_remove "${criu_dir}"
    fi

    # Monitor loop
    local start_time
    start_time="$(date +%s)"
    local timed_out=0
    local target_dump_pid=""

    while kill -0 "${unshare_pid}" 2> /dev/null; do
        if (( timeout_sec > 0 && timed_out == 0 )); then
            local current_time
            current_time="$(date +%s)"
            local elapsed=$(( current_time - start_time ))
            if (( elapsed >= timeout_sec )); then
                log_warn "Chroot execution reached timeout (${timeout_sec}s)." \
                    "Initiating CRIU live dump."
                timed_out=1

                # Locate the primary target process to dump
                local candidate_pids=()
                local p
                for p in /proc/[0-9]*; do
                    if is_chroot_process "${p}" "${real_target_root}"; then
                        candidate_pids+=("${p##*/}")
                    fi
                done

                # Target the highest-level child of init
                for p in "${candidate_pids[@]}"; do
                    local ppid
                    ppid="$(awk '/PPid:/ {print $2}' "/proc/${p}/status" \
                        2> /dev/null || true)"
                    if [[ "${ppid}" == "${init_pid}" || \
                        "${ppid}" == "${unshare_pid}" ]]; then
                        target_dump_pid="${p}"
                        break
                    fi
                done

                if [[ -z "${target_dump_pid}" ]]; then
                    target_dump_pid="${init_pid}"
                fi

                log_info "Checkpointing process tree at PID ${target_dump_pid}"
                create_directory "${criu_dir}"
                local dump_log="${criu_dir}/dump.log"

                local -a ext_mount_args=()
                while IFS=' ' read -r _ mnt_dest _; do
                    if [[ "${mnt_dest}" == "${real_target_root}"* ]]; then
                        local rel_dest="${mnt_dest#"${real_target_root}"}"
                        [[ -z "${rel_dest}" ]] && rel_dest="/"
                        ext_mount_args+=(
                            "--ext-mount-map" "${rel_dest}:${mnt_dest}"
                        )
                    fi
                done < /proc/mounts

                local criu_dump_cmd=(
                    "criu" "dump"
                    "--tree" "${target_dump_pid}"
                    "--images-dir" "${criu_dir}"
                    "--work-dir" "${criu_dir}"
                    "--shell-job"
                    "--tcp-established"
                    "--file-locks"
                    "--link-remap"
                    "--leave-stopped"
                    "--track-mem"
                    "--log-file" "${dump_log}"
                    "--verbose=4"
                    "${ext_mount_args[@]}"
                )

                local dump_exit=0
                "${criu_dump_cmd[@]}" >> "${runner_log}" 2>&1 || \
                    dump_exit="${?}"

                if (( dump_exit == 0 )); then
                    log_info "CRIU checkpoint dumped successfully."
                    exit_code=124
                else
                    log_error "CRIU dump failed with code ${dump_exit}."
                    if [[ -f "${dump_log}" ]]; then
                        tail -n 100 "${dump_log}" >&2 || true
                    fi
                    exit_code=1
                fi

                kill -9 "${unshare_pid}" 2> /dev/null || true
                break
            fi
        fi
        sleep 1
    done

    if (( timed_out == 0 )); then
        wait "${unshare_pid}" || exit_code="${?}"
    fi

    # Unmount inside real_target_root if anything was left behind
    local mounted_entry
    while IFS= read -r mounted_entry; do
        if [[ -n "${mounted_entry}" ]]; then
            umount -l "${mounted_entry}" 2> /dev/null || true
        fi
    done < <(awk -v root="${real_target_root}" \
        '$2 ~ "^" root { print $2 }' /proc/mounts | sort -r)

    if findmnt --mountpoint "${real_target_root}" > /dev/null 2>&1; then
        umount -l "${real_target_root}" 2> /dev/null || true
    fi
    rmdir "${real_target_root}/.oldroot" 2> /dev/null || true
    kill_chroot_processes "${real_target_root}"

    return "${exit_code}"
}

chroot_run() {
    local target_root="${1}"
    log_info "Running command in chroot for ${target_root}"

    shift

    if [[ ( -v CHROOT_TIMEOUT && -n "${CHROOT_TIMEOUT}" ) || \
        -d "${target_root}/.criu" ]]; then
        local exit_code="0"
        chroot_run_criu "${target_root}" "${*}" || exit_code="${?}"
        return "${exit_code}"
    fi

    mount_chroot_filesystems "${target_root}"

    local exit_code="0"
    chroot "${target_root}" /bin/bash --login -e \
        -c "${*}" || exit_code="${?}"

    kill_chroot_processes "${target_root}"
    unmount_chroot_filesystems

    return "${exit_code}"
}

# === Target System Setup ===

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

prepare_target_subvolumes() {
    local root_target_dev="${1}"
    log_info "Creating Btrfs subvolumes on ${root_target_dev}"

    local btrfs_tmp_dir
    btrfs_tmp_dir="$(mktemp --directory)"
    mount --types "btrfs" "${root_target_dev}" "${btrfs_tmp_dir}"
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

    local root_subvol_id
    root_subvol_id="$(btrfs subvolume list "${btrfs_tmp_dir}" | awk \
        '$NF == "@" {print $2}')"
    btrfs subvolume set-default "${root_subvol_id}" "${btrfs_tmp_dir}"

    umount "${btrfs_tmp_dir}"
    remove_directory "${btrfs_tmp_dir}"
}

mount_target_subvolumes() {
    local array_name="${1}"
    local root_target_dev="${2}"
    local boot_partition="${3}"
    local target_root="${4}"
    local swap_size_gib="${5:-0}"
    log_info "Mounting target subvolumes to ${target_root}"

    create_directory "${target_root}"
    managed_mount "${array_name}" \
        --options "${ROOT_MOUNT_OPTIONS},subvol=@" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}"

    create_directory "${target_root}/boot"
    managed_mount "${array_name}" \
        --options "${BOOT_MOUNT_OPTIONS}" \
        --types "vfat" \
        "${boot_partition}" \
        "${target_root}/boot"

    create_directory "${target_root}/home"
    managed_mount "${array_name}" \
        --options "${HOME_MOUNT_OPTIONS},subvol=@home" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/home"

    create_directory "${target_root}/var/log"
    managed_mount "${array_name}" \
        --options "${VAR_LOG_MOUNT_OPTIONS},subvol=@var_log" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/var/log"

    create_directory "${target_root}/var/tmp"
    managed_mount "${array_name}" \
        --options "${VAR_TMP_MOUNT_OPTIONS},subvol=@var_tmp" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/var/tmp"
    chmod 1777 "${target_root}/var/tmp"

    create_directory "${target_root}/var/tmp/portage"
    managed_mount "${array_name}" \
        --options "${PORTAGE_TMP_MOUNT_OPTIONS},subvol=@var_tmp_portage" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/var/tmp/portage"
    chmod 0775 "${target_root}/var/tmp/portage"

    create_directory "${target_root}/var/cache/binpkgs"
    managed_mount "${array_name}" \
        --options \
        "${VAR_CACHE_BINPKGS_MOUNT_OPTIONS},subvol=@var_cache_binpkgs" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/var/cache/binpkgs"
    chmod 0755 "${target_root}/var/cache/binpkgs"

    create_directory "${target_root}/var/cache/binhost"
    managed_mount "${array_name}" \
        --options \
        "${VAR_CACHE_BINHOST_MOUNT_OPTIONS},subvol=@var_cache_binhost" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/var/cache/binhost"
    chmod 0755 "${target_root}/var/cache/binhost"

    create_directory "${target_root}/swap"
    managed_mount "${array_name}" \
        --options "${SWAP_MOUNT_OPTIONS},subvol=@swap" \
        --types "btrfs" \
        "${root_target_dev}" \
        "${target_root}/swap"

    if (( swap_size_gib > 0 )); then
        btrfs filesystem mkswapfile --size "${swap_size_gib}g" \
            "${target_root}/swap/swapfile"
    fi
}

generate_target_fstab() {
    local target_root="${1}"
    local root_uuid="${2}"
    local boot_uuid="${3}"
    log_info "Generating fstab for ${target_root}"

    local fstab_file="${target_root}/etc/fstab"
    local portage_opts="${PORTAGE_TMP_MOUNT_OPTIONS},subvol=@var_tmp_portage"
    local binpkg_opts=\
"${VAR_CACHE_BINPKGS_MOUNT_OPTIONS},subvol=@var_cache_binpkgs"
    local binhost_opts=\
"${VAR_CACHE_BINHOST_MOUNT_OPTIONS},subvol=@var_cache_binhost"

    local fstab_content
    IFS= read -d "" -r fstab_content << EOF || true
UUID=${root_uuid} / btrfs ${ROOT_MOUNT_OPTIONS},subvol=@ 0 0
UUID=${boot_uuid} /boot vfat ${BOOT_MOUNT_OPTIONS} 0 2
UUID=${root_uuid} /home btrfs ${HOME_MOUNT_OPTIONS},subvol=@home 0 0
UUID=${root_uuid} /var/log btrfs ${VAR_LOG_MOUNT_OPTIONS},subvol=@var_log 0 0
UUID=${root_uuid} /var/tmp btrfs ${VAR_TMP_MOUNT_OPTIONS},subvol=@var_tmp 0 0
UUID=${root_uuid} /var/tmp/portage btrfs ${portage_opts} 0 0
UUID=${root_uuid} /var/cache/binpkgs btrfs ${binpkg_opts} 0 0
UUID=${root_uuid} /var/cache/binhost btrfs ${binhost_opts} 0 0
UUID=${root_uuid} /swap btrfs ${SWAP_MOUNT_OPTIONS},subvol=@swap 0 0
/swap/swapfile none swap defaults 0 0
tmpfs /tmp tmpfs defaults,noatime,nodev,nosuid,noexec,mode=1777 0 0
tmpfs /dev/shm tmpfs defaults,noatime,nodev,nosuid,noexec 0 0
EOF
    printf "%s" "${fstab_content}" > "${fstab_file}"
}

install_secureboot_cert() {
    local target_root="${1}"
    local dest_cert="${target_root}/boot/Secure Boot Certificate.der"

    if [[ -n "${SECUREBOOT_CERT:-}" ]]; then
        log_info "Exporting Secure Boot certificate to ESP"
        openssl x509 -inform "PEM" -outform "DER" \
            -out "${dest_cert}" \
            <<< "${SECUREBOOT_CERT}"
    elif [[ -f "/boot/Secure Boot Certificate.der" ]]; then
        log_info "Copying Secure Boot certificate to ESP"
        copy_file "/boot/Secure Boot Certificate.der" "${dest_cert}"
    fi
}

persist_ebuild_repositories() {
    local target_root="${1}"
    local repo_entry repo_name

    for repo_entry in "${_repo_entries[@]}"; do
        repo_name="${repo_entry%% *}"
        log_info "Copying ${repo_name} repository to target"
        cp --archive "${LOCAL_REPOS_DIR}/${repo_name}/." \
            "${target_root}/var/db/repos/${repo_name}"
    done

    chown -R portage:portage "${target_root}/var/db/repos"
}

finalize_target_portage() {
    local target_root="${1}"
    local profile="${2}"

    remove_portage_configuration "${target_root}"
    configure_portage_profile "${target_root}" "${profile}"
    unmount_repos
    persist_ebuild_repositories "${target_root}"
    create_empty_file "${target_root}/etc/portage/make.conf"
}
