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
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "tar"
    "udevadm"
    "umount"
)

readonly _COMMON_SH_INCLUDED=1
readonly WORK_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
env_file="${WORK_DIR}/.env"
if [[ -f "${env_file}" ]]; then
    # Preserve environment variables already set before sourcing .env so
    # caller/CI overrides take precedence over values in the .env file.
    declare -A _preserved_env=()
    while IFS= read -r _var_name; do
        if [[ -n "${_var_name}" && -n "${!_var_name}" ]]; then
            _preserved_env["${_var_name}"]="${!_var_name}"
        fi
    done < <(compgen -e)

    source "${env_file}"

    for _var_name in "${!_preserved_env[@]}"; do
        printf -v "${_var_name}" '%s' "${_preserved_env[${_var_name}]}"
        export "${_var_name}"
    done
    unset _preserved_env _var_name
fi
unset env_file
readonly BUILD_DIR="${WORK_DIR}/build"
readonly LOCAL_REPOS_DIR="${BUILD_DIR}/repos"
readonly GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL:-http://distfiles.gentoo.org}"
readonly PORTAGE_GPG_DIR="/var/lib/portage/gnupg-sign"
readonly PORTAGE_SECUREBOOT_DIR="/var/lib/portage/secureboot"

# === Logging Helpers ===

if [[ -t 1 ]]; then
    _C_RESET='\033[0m'
    _C_GREEN='\033[1;32m'
    _C_YELLOW='\033[1;33m'
    _C_RED='\033[1;31m'
    _C_GRAY='\033[1;30m'
else
    _C_RESET='' _C_GREEN='' _C_YELLOW='' _C_RED='' _C_GRAY=''
fi

log_info() {
    printf "${_C_GREEN}[%s]${_C_RESET} %s\n" "${0##*/}" "${*}"
}
log_warn() {
    printf "${_C_YELLOW}[%s] WARNING:${_C_RESET} %s\n" "${0##*/}" "${*}" >&2
}
log_error() {
    printf "${_C_RED}[%s] ERROR:${_C_RESET} %s\n" "${0##*/}" "${*}" >&2
}
log_debug() {
    if (( ${DEBUG:-${FLUFFY_DEBUG:-0}} )); then
        printf "${_C_GRAY}[%s] DEBUG:${_C_RESET} %s\n" "${0##*/}" "${*}"
    fi
}

# === Command Requirements ===

check_root() {
    if (( EUID != 0 )); then
        printf "%s\n" "You must be root to run this script." >&2
        exit 1
    fi
    if [[ "$(</proc/mounts)" == *" ${WORK_DIR} "* ]]; then
        mount --make-rprivate "${WORK_DIR}" 2> /dev/null || true
    fi
}

check_required_commands() {
    local missing_commands=()
    local -A seen=()
    for command in "${required_commands[@]}"; do
        if [[ -v seen["${command}"] ]]; then
            continue
        fi
        seen["${command}"]=1

        if ! command -v "${command}" > /dev/null 2>&1; then
            missing_commands+=("${command}")
        fi
    done

    if (( ${#missing_commands[@]} > 0 )); then
        local missing_str
        missing_str="$(printf " %s" "${missing_commands[@]}")"
        log_error "Missing required commands:${missing_str}"
        exit 1
    fi
}

# === CLI Argument Parsing ===

declare -a _cli_keys=()
declare -A _cli_opt_map=()
declare -A _cli_short_map=()
declare -A _cli_long_map=()
declare -A _cli_desc_map=()
declare -A _cli_req_map=()
declare -A _cli_def_map=()
declare -A _cli_flag_map=()

cli_init() {
    _cli_keys=()
    _cli_opt_map=()
    _cli_short_map=()
    _cli_long_map=()
    _cli_desc_map=()
    _cli_req_map=()
    _cli_def_map=()
    _cli_flag_map=()
}

cli_define_option() {
    local var_name="${1}"
    local switches="${2}"
    local desc="${3}"
    local required="${4:-0}"
    local default="${5:-}"

    _cli_keys+=("${var_name}")
    _cli_desc_map["${var_name}"]="${desc}"
    _cli_req_map["${var_name}"]="${required}"
    _cli_def_map["${var_name}"]="${default}"
    _cli_flag_map["${var_name}"]=0

    local switch
    local -a parts=()
    IFS="|" read -ra parts <<< "${switches}"
    for switch in "${parts[@]}"; do
        _cli_opt_map["${switch}"]="${var_name}"
        if [[ "${switch}" =~ ^-- ]]; then
            _cli_long_map["${var_name}"]="${switch}"
        elif [[ "${switch}" =~ ^-[a-zA-Z0-9]$ ]]; then
            _cli_short_map["${var_name}"]="${switch}"
        fi
    done
}

cli_define_flag() {
    local var_name="${1}"
    local switches="${2}"
    local desc="${3}"
    local default="${4:-0}"

    cli_define_option "${var_name}" "${switches}" "${desc}" 0 "${default}"
    _cli_flag_map["${var_name}"]=1
}

cli_show_help() {
    local script_name
    script_name="$(basename "${0}")"
    printf "Usage: %s [options]\n\nOptions:\n" "${script_name}"
    local key
    for key in "${_cli_keys[@]}"; do
        local sw_short="${_cli_short_map[${key}]:-}"
        local sw_long="${_cli_long_map[${key}]:-}"
        local sw_comb="${sw_long:-${sw_short}}"
        if [[ -n "${sw_short}" && -n "${sw_long}" ]]; then
            sw_comb="${sw_short}, ${sw_long}"
        fi
        if (( _cli_flag_map[${key}] == 0 )); then
            sw_comb="${sw_comb} <val>"
        fi

        local suffix=""
        if (( _cli_flag_map[${key}] == 1 )); then
            if [[ -n "${_cli_def_map[${key}]}" && \
                  "${_cli_def_map[${key}]}" != "0" ]]; then
                suffix=" (default: ${_cli_def_map[${key}]})"
            fi
        elif (( _cli_req_map[${key}] == 1 )); then
            suffix=" (required)"
        elif [[ -n "${_cli_def_map[${key}]}" ]]; then
            suffix=" (default: ${_cli_def_map[${key}]})"
        fi

        printf "  %-24s %s%s\n" "${sw_comb}" \
            "${_cli_desc_map[${key}]}" "${suffix}"
    done
    printf "  %-24s %s\n" "-h, --help" "Show this help message and exit"
}

cli_parse() {
    local key
    for key in "${_cli_keys[@]}"; do
        printf -v "${key}" "%s" "${_cli_def_map[${key}]}"
    done

    local -A _cli_seen=()

    while (( $# > 0 )); do
        local opt="${1}"
        case "${opt}" in
            -h|--help)
                cli_show_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            --*=* | -[a-zA-Z0-9]=*)
                local opt_name="${opt%%=*}"
                local var_name="${_cli_opt_map[${opt_name}]:-}"
                if [[ -z "${var_name}" ]]; then
                    printf "Error: Unknown option '%s'\n" "${opt_name}" >&2
                    cli_show_help >&2
                    exit 1
                fi
                if (( _cli_flag_map[${var_name}] == 1 )); then
                    printf "Error: Option '%s' is a flag and takes no value\n" \
                        "${opt_name}" >&2
                    cli_show_help >&2
                    exit 1
                fi
                printf -v "${var_name}" "%s" "${opt#*=}"
                _cli_seen["${var_name}"]=1
                shift
                ;;
            --* | -[a-zA-Z0-9])
                local var_name="${_cli_opt_map[${opt}]:-}"
                if [[ -z "${var_name}" ]]; then
                    printf "Error: Unknown option '%s'\n" "${opt}" >&2
                    cli_show_help >&2
                    exit 1
                fi
                if (( _cli_flag_map[${var_name}] == 1 )); then
                    printf -v "${var_name}" "%s" 1
                    _cli_seen["${var_name}"]=1
                    shift
                else
                    if (( $# < 2 )); then
                        printf "Error: Option '%s' requires an argument\n" \
                            "${opt}" >&2
                        cli_show_help >&2
                        exit 1
                    fi
                    printf -v "${var_name}" "%s" "${2}"
                    _cli_seen["${var_name}"]=1
                    shift 2
                fi
                ;;
            *)
                printf "Error: Unexpected argument '%s'\n" "${opt}" >&2
                cli_show_help >&2
                exit 1
                ;;
        esac
    done

    for key in "${_cli_keys[@]}"; do
        if (( _cli_req_map[${key}] == 1 )) && \
           [[ -z "${_cli_seen[${key}]:-}" ]]; then
            local sw_display="${_cli_long_map[${key}]:-}"
            sw_display="${sw_display:-${_cli_short_map[${key}]:-${key}}}"
            printf "Error: Missing required option '%s'\n" \
                "${sw_display}" >&2
            cli_show_help >&2
            exit 1
        fi
    done
}

# === File and Directory Helpers ===

create_directory() {
    if [[ -d "${1}" ]]; then
        return
    fi
    log_debug "Creating ${1}"
    mkdir --parents "${1}"
}

remove_file() {
    log_debug "Removing ${1}"
    rm "${1}"
}

remove_directory() {
    log_debug "Removing directory ${1}"
    rmdir "${1}"
}

force_remove() {
    log_debug "Force removing ${1}"
    rm --force --recursive "${1}"
}

copy_file() {
    log_debug "Copying ${1} to ${2}"
    cp --dereference "${1}" "${2}"
}

recursive_copy() {
    log_debug "Recursively copying ${1} to ${2}"
    cp --dereference --recursive "${1}" "${2}"
}

create_empty_file() {
    log_debug "Creating empty file ${1}"
    > "${1}"
}

create_file() {
    log_debug "Creating file ${1}"
    printf "%s\n" "${2}" > "${1}"
}

create_symbolic_link() {
    log_debug "Creating symbolic link from ${1} to ${2}"
    ln --force --no-dereference --symbolic "${1}" "${2}"
}

# === Archive Helpers ===

tar_extract() {
    local archive="${1}"
    local target_dir="${2}"
    shift 2

    local -a compress_opts=()
    if [[ "${archive}" == *.tar.zst || "${archive}" == *.zst ]]; then
        compress_opts=(--use-compress-program="zstd --long=31")
    fi

    tar --directory="${target_dir}" \
        --extract \
        --file="${archive}" \
        --numeric-owner \
        --preserve-permissions \
        "${compress_opts[@]}" \
        --xattrs-include="*.*" \
        "${@}"
}

tar_create() {
    local archive="${1}"
    local source_dir="${2}"
    shift 2

    tar --create \
        --directory="${source_dir}" \
        --file="${archive}" \
        --numeric-owner \
        --preserve-permissions \
        --use-compress-program="zstd --long=31 --threads=0 -9" \
        --xattrs-include="*.*" \
        "${@}"
}

# === Configuration Parsing ===

# Splits "repo:profile/path" into "repo profile/path", defaulting to "gentoo"
# when no repository prefix is specified.
parse_profile() {
    local target_profile="${1//$'\r'/}"
    local repo repo_profile
    IFS=":" read -r repo repo_profile <<< "${target_profile}"
    if [[ -z "${repo_profile}" ]]; then
        repo_profile="${repo}"
        repo="gentoo"
    fi
    printf "%s %s\n" "${repo}" "${repo_profile}"
}

# === Mount Management ===

_registered_mount_arrays=()
declare -A _registered_mount_arrays_seen=()

managed_mount() {
    local array_name="${1}"
    declare -n mounts_array_name="${array_name}"
    shift

    # The mount target is always the last argument in standard mount syntax
    local target="${*: -1}"

    log_debug "Mounting ${target}"
    mount "${@}"

    mounts_array_name+=("${target}")
    if [[ ! -v _registered_mount_arrays_seen["${array_name}"] ]]; then
        _registered_mount_arrays_seen["${array_name}"]=1
        _registered_mount_arrays+=("${array_name}")
    fi
}

managed_unmount_all() {
    declare -n mounts_array_name="${1}"

    local exit_code="0"
    local remaining_mounts=()
    local i
    # Unmount in reverse order so nested child mounts detach before parents.
    for (( i=${#mounts_array_name[@]}-1; i>=0; i-- )); do
        local m="${mounts_array_name[$i]}"
        # Check space-delimited target in /proc/mounts directly to avoid
        # requiring util-linux mountpoint(1).
        if [[ "$(</proc/mounts)" == *" ${m} "* ]]; then
            log_debug "Unmounting ${m}"
            if ! umount --recursive "${m}"; then
                exit_code="${?}"
                remaining_mounts+=("${m}")
            fi
        fi
    done

    mounts_array_name=("${remaining_mounts[@]}")
    if (( exit_code != 0 )); then
        log_error "Error unmounting one or more filesystems"
        return "${exit_code}"
    fi
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
    while IFS= read -r repo_entry; do
        if [[ -z "${repo_entry}" ]]; then continue; fi

        _repo_entries+=("${repo_entry}")
    done <<< "${REPOS}"

    readonly _ebuild_repositories_loaded=1
}

download_ebuild_repositories() {
    if [[ -v _ebuild_repositories_downloaded ]]; then
        return
    fi

    log_info "Downloading ebuild repositories"

    import_bundled_keys
    import_public_keys

    load_ebuild_repositories

    for repo_entry in "${_repo_entries[@]}"; do
        local repo_name repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local repo_dir="${LOCAL_REPOS_DIR}/${repo_name}"

        if [[ -d "${repo_dir}" ]]; then
            log_info "Updating ${repo_name} in ${repo_dir}"
            git -C "${repo_dir}" fetch --depth 1 origin
            git -C "${repo_dir}" reset --hard FETCH_HEAD
        else
            log_info "Cloning ${repo_url} into ${repo_dir}"
            git clone --depth 1 --quiet "${repo_url}" "${repo_dir}"
        fi
        # Enforce GPG commit signature verification on all ebuild repositories
        # using bundled keys (keys/*.asc) and REPO_PUBLIC_KEYS.
        log_info "Verifying latest commit signature for ${repo_name}" \
            "in ${repo_dir}"
        git -C "${repo_dir}" verify-commit HEAD
    done

    readonly _ebuild_repositories_downloaded=1
}

# Normalizes "/" or empty root to "" so path concatenations like
# "${target_root}/etc/portage" do not produce leading "//".
normalize_target_root() {
    local raw_root="${1:-/}"
    local -n out_root="${2}"
    local -n out_display="${3}"

    if [[ "${raw_root}" == "/" || -z "${raw_root}" ]]; then
        out_root=""
        out_display="host system (/)"
    else
        out_root="${raw_root%/}"
        out_display="${out_root}"
    fi
}

configure_ebuild_repositories() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    log_info "Configuring ebuild repositories for ${target_display}"

    download_ebuild_repositories

    load_ebuild_repositories

    local repos_conf_dir="${target_root}/etc/portage/repos.conf"
    create_directory "${repos_conf_dir}"

    for repo_entry in "${_repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local repo_conf_file="${repos_conf_dir}/${repo_name}.conf"
        log_debug "Creating ${repo_conf_file}"
        local repo_conf_content
        IFS= read -d "" -r repo_conf_content << EOF || true
[${repo_name}]
location = /var/db/repos/${repo_name}
sync-type = git
sync-uri = ${repo_url}
EOF
        printf "%s" "${repo_conf_content}" > "${repo_conf_file}"
    done
}

_active_repo_mounts=()
mount_repos() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    log_info "Mounting ebuild repositories for ${target_display}"

    load_ebuild_repositories

    local repos_dir="${target_root}/var/db/repos"
    create_directory "${repos_dir}"

    for repo_entry in "${_repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local source_repo_dir="${LOCAL_REPOS_DIR}/${repo_name}"
        local target_repo_dir="${repos_dir}/${repo_name}"

        create_directory "${target_repo_dir}"

        log_debug "Mounting ${source_repo_dir} to ${target_repo_dir}"
        managed_mount "_active_repo_mounts" --bind --options "ro" \
            "${source_repo_dir}" "${target_repo_dir}"
    done
}

unmount_repos() {
    log_info "Unmounting ebuild repositories"
    managed_unmount_all "_active_repo_mounts"
}

# === GPG and Security ===

import_bundled_keys() {
    if [[ -v _BUNDLED_KEYS_IMPORTED ]]; then
        return
    fi

    local key_file
    for key_file in "${WORK_DIR}"/keys/*.asc; do
        if [[ -f "${key_file}" ]]; then
            log_info "Importing bundled key $(basename "${key_file}")"
            gpg --quiet --import "${key_file}"

            gpg --with-colons --show-keys "${key_file}" | \
                awk -F: '/^fpr/ {print $10 ":6:"}' | \
                gpg --batch --import-ownertrust --quiet
        fi
    done

    readonly _BUNDLED_KEYS_IMPORTED=1
}

import_public_keys() {
    if [[ -v _public_keys_imported ]]; then
        return
    fi

    log_info "Importing public keys"

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

        gpg --show-keys --with-colons <<< "${all_keys}" | \
            awk -F: '/^fpr/ {print $10 ":6:"}' | \
            gpg --batch --import-ownertrust --quiet
    fi

    readonly _public_keys_imported=1
}

# === Portage Configuration ===

remove_portage_configuration() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    log_info "Removing Portage configuration for ${target_display}"

    find "${target_root}/etc/portage" -mindepth 1 -maxdepth 1 -exec rm --force \
        --recursive {} +
}

configure_portage_profile() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    local profile="${2}"
    log_info "Configuring Portage profile for ${target_display}"

    local portage_conf_dir="${target_root}/etc/portage"
    create_directory "${portage_conf_dir}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local portage_conf_profile_dir="${portage_conf_dir}/make.profile"
    local relative_repo_profile_dir=\
"../../var/db/repos/${repo}/profiles/${repo_profile}"
    create_symbolic_link "${relative_repo_profile_dir}" \
        "${portage_conf_profile_dir}"
}

configure_portage() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    local profile="${2}"
    local portage_conf_name="${3}"
    log_info "Applying Portage configuration for ${target_display}"

    configure_portage_profile "${target_root}" "${profile}"

    local portage_conf_dir="${target_root}/etc/portage"
    recursive_copy "${WORK_DIR}/portage/${portage_conf_name}/." \
        "${portage_conf_dir}"

    configure_ebuild_repositories "${target_root}"

    if [[ -z "${target_root}" ]]; then
        if command -v getuto > /dev/null 2>&1; then
            getuto
        else
            log_warn "getuto command not found on host, skipping..."
        fi
    else
        chroot_run "${target_root}" 'getuto'
    fi

    local portage_gnupg_dir="${target_root}/etc/portage/gnupg"
    create_directory "${portage_gnupg_dir}"

    # Build scripts derive the verification key from SIGNING_KEY; live
    # installer environments have no private key and use BINPKG_PUBLIC_KEY.
    if [[ -n "${SIGNING_KEY:-}" ]] && \
        declare -F import_signing_key > /dev/null; then
        import_signing_key
        gpg --batch --export "${_signing_key_fingerprint}" | \
            gpg --batch --homedir "${portage_gnupg_dir}" --import

        printf "%s\n" "${_signing_key_fingerprint}:6:" | \
            gpg --batch --homedir "${portage_gnupg_dir}" \
            --import-ownertrust --quiet
    else
        if [[ -n "${BINPKG_PUBLIC_KEY//[[:space:]]/}" ]]; then
            gpg --batch --homedir "${portage_gnupg_dir}" \
                --import --quiet <<< "${BINPKG_PUBLIC_KEY}"
            gpg --batch --homedir "${portage_gnupg_dir}" \
                --list-keys --with-colons 2> /dev/null | \
                awk -F: '/^fpr/ {print $10 ":6:"}' | \
                gpg --batch --homedir "${portage_gnupg_dir}" \
                    --import-ownertrust --quiet
        fi
    fi

    gpg --batch --check-trustdb \
        --homedir "${portage_gnupg_dir}" 2> /dev/null || true
    # Portage drops root privileges to the portage user during signature
    # verification, so trustdb.gpg must be world-readable.
    chmod ugo+r "${portage_gnupg_dir}/trustdb.gpg" 2> /dev/null || true
    gpgconf --homedir "${portage_gnupg_dir}" --kill all 2> /dev/null || true

    # Mask check-chroot plugin to allow kernel-install in chroot
    create_directory "${target_root}/etc/kernel/install.d"
    create_symbolic_link "/dev/null" \
        "${target_root}/etc/kernel/install.d/05-check-chroot.install"
}

_binpkg_repo_entries=()
load_binpkg_repositories() {
    if [[ -v _binpkg_repositories_loaded ]]; then
        return
    fi

    local repo_entry
    while IFS= read -r repo_entry; do
        if [[ -z "${repo_entry}" ]]; then continue; fi

        _binpkg_repo_entries+=("${repo_entry}")
    done <<< "${BINPKG_REPOS}"

    readonly _binpkg_repositories_loaded=1
}

configure_portage_binary_packages() {
    local target_root target_display
    normalize_target_root "${1-}" target_root target_display
    local profile="${2}"
    log_info "Configuring Portage binary packages for ${target_display}"

    load_binpkg_repositories

    local repo_dir="${target_root}/etc/portage/binrepos.conf"
    create_directory "${repo_dir}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local repo_entry
    for repo_entry in "${_binpkg_repo_entries[@]}"; do
        local repo_name repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local binpkg_repo_conf_file="${repo_dir}/${repo_name}.conf"
        log_debug "Creating ${binpkg_repo_conf_file}"
        local binpkg_repo_conf_content
        IFS= read -d "" -r binpkg_repo_conf_content << EOF || true
[${repo_name}]
sync-uri = ${repo_url}/${repo_profile}
EOF
        printf "%s" "${binpkg_repo_conf_content}" > "${binpkg_repo_conf_file}"
    done
}

# === Chroot Environment ===

_active_chroot_mounts=()
mount_chroot_filesystems() {
    local target_root="${1}"
    log_info "Mounting chroot filesystems for ${target_root}"

    create_directory "${target_root}/etc"
    # Avoid clobbering /etc/resolv.conf if it is already a symlink (e.g. to
    # systemd-resolved's stub-resolv.conf).
    if [[ ! -L "${target_root}/etc/resolv.conf" ]]; then
        cp --dereference --force "/etc/resolv.conf" \
            "${target_root}/etc/resolv.conf"
    fi

    local target_proc_dir="${target_root}/proc"
    create_directory "${target_proc_dir}"
    managed_mount "_active_chroot_mounts" --types "proc" "/proc" \
        "${target_root}/proc"
    local target_sys_dir="${target_root}/sys"
    create_directory "${target_sys_dir}"
    managed_mount "_active_chroot_mounts" --rbind "/sys" \
        "${target_root}/sys"
    mount --make-rslave "${target_root}/sys"
    local target_dev_dir="${target_root}/dev"
    create_directory "${target_dev_dir}"
    managed_mount "_active_chroot_mounts" --rbind "/dev" \
        "${target_root}/dev"
    mount --make-rslave "${target_root}/dev"
    local target_run_dir="${target_root}/run"
    create_directory "${target_run_dir}"
    managed_mount "_active_chroot_mounts" --bind "/run" \
        "${target_root}/run"
    mount --make-slave "${target_root}/run"
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
    if [[ -z "${target_root}" || "${target_root}" == "/" ]]; then
        return
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

    local pid exe
    for pid in "${pids[@]}"; do
        exe="$(basename "$(readlink "/proc/${pid}/exe" 2> /dev/null)" \
            2> /dev/null || true)"
        log_warn "Sending SIGTERM to lingering chroot process" \
            "${pid} (${exe:-unknown})"
        kill -s "TERM" "${pid}" 2> /dev/null || true
    done

    local iteration
    for (( iteration=0; iteration<300; iteration++ )); do
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

    log_error "Failed to terminate all chroot processes for ${target_root}"
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
    [[ -c "${target_root}/dev/console" ]] || \
        mknod -m 0600 "${target_root}/dev/console" c 5 1

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

    local m_dev m_point m_rest
    while IFS=" " read -r m_dev m_point m_rest; do
        if [[ "${m_point}" == "${real_target_root}/"* ]]; then
            local rel_mount="${m_point#"${real_target_root}"}"
            case "${rel_mount}" in
                /proc|/proc/*|/dev|/dev/*|/sys|/sys/*|/run|/run/*|/.oldroot*)
                    continue
                    ;;
            esac
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
}

chroot_run_criu() {
    local real_target_root
    real_target_root="$(realpath "${1}")"
    shift

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
        : > "${log_file}"

        local pidfile
        pidfile="$(mktemp)"
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
            -v4 -o "restore.log"; then
            rm --force "${pidfile}"
            if [[ -f "${criu_dir}/restore.log" ]]; then
                tail -n 50 "${criu_dir}/restore.log" >&2 || true
            fi
            log_error "CRIU restore failed for ${real_target_root}"
            return 1
        fi
        ns_init_pid="$(<"${pidfile}")"
        rm --force "${pidfile}"
        force_remove "${criu_dir}"
        log_info "Restored CRIU process tree (PID ${ns_init_pid})"
    else
        rm --force "${exit_file}" "${log_file}"
        touch "${log_file}"

        cat > "${cmd_file}" << EOF
#!/bin/bash
export TERM="dumb"
exec < /dev/null >> /var/tmp/.fluffy-chroot.log 2>&1
set +e
(
    source /etc/profile 2> /dev/null || true
    set -e
    ${*}
)
rc=\$?
printf "%s\n" "\${rc}" > /var/tmp/.fluffy-chroot.exit
exit "\${rc}"
EOF
        chmod 0755 "${cmd_file}"

        unshare --pid --fork setsid unshare --mount --uts --ipc /bin/bash -c "
            set -e
            mount --make-rprivate /
            mount --rbind '${real_target_root}' '${real_target_root}'
            cd '${real_target_root}'
            pivot_root . .oldroot
            mount -t proc proc /proc
            mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts \
                /dev/pts
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

    tail --follow=name --retry -n +1 "${log_file}" 2> /dev/null &
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
        kill "${tail_pid}" 2> /dev/null || true
        wait "${tail_pid}" 2> /dev/null || true

        log_warn "Timeout (${CHROOT_TIMEOUT}) reached; checkpointing with CRIU"
        wait_for_criu_safe_point "${real_target_root}"

        force_remove "${criu_dir}"
        create_directory "${criu_dir}"

        if ! criu dump \
            --tree "${ns_init_pid}" \
            --images-dir "${criu_dir}" \
            --file-locks \
            --link-remap \
            --ghost-limit "1G" \
            --tcp-close \
            "${ext_dump_args[@]}" \
            -v4 -o "dump.log"; then
            if [[ -f "${criu_dir}/dump.log" ]]; then
                tail -n 50 "${criu_dir}/dump.log" >&2 || true
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

    rm --force "${cmd_file}" "${exit_file}" "${log_file}"
    force_remove "${criu_dir}"
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
