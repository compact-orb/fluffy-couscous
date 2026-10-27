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
    local target="${1}"
    log_debug "Force removing ${target}"

    if [[ -d "${target}" ]]; then
        local real_target
        real_target="$(realpath "${target}" 2> /dev/null || \
            printf "%s" "${target}")"
        local -a leftover_mounts=()
        local mountpoint
        while IFS= read -r mountpoint; do
            if [[ "${mountpoint}" == "${real_target}" || \
                "${mountpoint}" == "${real_target}/"* ]]; then
                leftover_mounts+=("${mountpoint}")
            fi
        done < <(awk '{print $2}' /proc/mounts 2> /dev/null || true)

        if (( ${#leftover_mounts[@]} > 0 )); then
            local i
            for (( i=${#leftover_mounts[@]}-1; i>=0; i-- )); do
                log_warn "Mount remaining at ${leftover_mounts[$i]};" \
                    "lazy unmounting before removal"
                umount --recursive --lazy "${leftover_mounts[$i]}" \
                    2> /dev/null || true
            done
        fi
    fi

    rm --force --recursive "${target}"
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
    ln --force --symbolic "${1}" "${2}"
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
    local target_profile="${1}"
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
            if ! umount --recursive "${m}" 2> /dev/null; then
                sleep 1
                if ! umount --recursive "${m}" 2> /dev/null; then
                    log_warn "Standard unmount failed for ${m}; lazy unmounting"
                    if ! umount --recursive --lazy "${m}"; then
                        exit_code="${?}"
                        remaining_mounts+=("${m}")
                    fi
                fi
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
                awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
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
            awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
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
                awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
                gpg --batch --homedir "${portage_gnupg_dir}" \
                    --import-ownertrust --quiet
        fi
    fi

    gpg --batch --check-trustdb \
        --homedir "${portage_gnupg_dir}" 2> /dev/null || true
    # Portage drops root privileges to the portage user during signature
    # verification, so trustdb.gpg must be world-readable.
    chmod ugo+r "${portage_gnupg_dir}/trustdb.gpg" 2> /dev/null || true

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
kill_chroot_processes() {
    local target_root
    target_root="$(realpath "${1}")"
    if [[ -z "${target_root}" || "${target_root}" == "/" ]]; then
        return
    fi

    local iteration
    for (( iteration=0; iteration<10; iteration++ )); do
        local -a pids=()
        local p
        for p in /proc/[0-9]*; do
            if [[ -d "${p}" ]]; then
                local root_link
                if root_link="$(readlink "${p}/root" 2> /dev/null)" && \
                    [[ "${root_link}" == "${target_root}" ]]; then
                    pids+=("${p##*/}")
                fi
            fi
        done

        if (( ${#pids[@]} == 0 )); then
            return 0
        fi

        local pid
        for pid in "${pids[@]}"; do
            local exe
            exe="$(basename "$(readlink "/proc/${pid}/exe" 2> /dev/null)" \
                2> /dev/null || true)"
            log_warn "Killing lingering chroot process ${pid} (${exe:-unknown})"
            kill -s KILL "${pid}" 2> /dev/null || true
        done
        sleep 0.5
    done
}

chroot_run() {
    local target_root="${1}"
    log_info "Running command in chroot for ${target_root}"

    mount_chroot_filesystems "${target_root}"

    shift

    local -a timeout_cmd=()
    if [[ -v CHROOT_TIMEOUT && -n "${CHROOT_TIMEOUT}" ]]; then
        timeout_cmd=(timeout --kill-after="60s" --signal="TERM" \
            "${CHROOT_TIMEOUT}")
    fi

    local exit_code="0"
    "${timeout_cmd[@]}" chroot "${target_root}" /bin/bash --login -e \
        -c "${*}" || exit_code="${?}"

    kill_chroot_processes "${target_root}"
    unmount_chroot_filesystems

    return "${exit_code}"
}
