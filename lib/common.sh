# Caller scripts declare a required_commands=() array first,
# and then source this file. This += appends these base requirements to the
# caller's array. The caller can then add its own specifics.
required_commands+=(
    "awk"
    "chmod"
    "chroot"
    "cp"
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
    "umount"
)

readonly _COMMON_SH_INCLUDED=1
readonly WORK_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
env_file="${WORK_DIR}/.env"
if [[ -f "$env_file" ]]; then
    source "$env_file"
fi
readonly BUILD_DIR="${WORK_DIR}/build"
readonly LOCAL_REPOS_DIR="${BUILD_DIR}/repos"
readonly GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL:-"http://distfiles.gentoo.org"}"
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

log_info() { printf "${_C_GREEN}[%s]${_C_RESET} %s\n" "${0##*/}" "${*}"; }
log_warn() { printf "${_C_YELLOW}[%s] WARNING:${_C_RESET} %s\n" "${0##*/}" "${*}" >&2; }
log_error() { printf "${_C_RED}[%s] ERROR:${_C_RESET} %s\n" "${0##*/}" "${*}" >&2; }
log_debug() {
    if (( ${DEBUG:-${FLUFFY_DEBUG:-0}} )); then
        printf "${_C_GRAY}[%s] DEBUG:${_C_RESET} %s\n" "${0##*/}" "${*}"
    fi
}

# === Command Requirements ===

check_required_commands() {
    local missing_commands=()
    local -A seen=()
    for command in "${required_commands[@]}"; do
        if [[ -v seen["$command"] ]]; then
            continue
        fi
        seen["$command"]=1

        if ! command -v "${command}" > /dev/null 2>&1; then
            missing_commands+=("${command}")
        fi
    done

    if (( ${#missing_commands[@]} > 0)); then
        log_error "Missing required commands:$(printf " %s" "${missing_commands[@]}")"
        exit 1
    fi
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
    ln --force --symbolic "${1}" "${2}"
}

# === Configuration Parsing ===

parse_profile() {
    local target_profile="${1}"
    local repo repo_profile
    IFS=":" read -r repo repo_profile <<< "${target_profile}"
    if [[ -z "${repo_profile}" ]]; then
        repo_profile="${repo}"
        repo="gentoo"
    fi
    echo "${repo} ${repo_profile}"
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
    local i
    for (( i=${#mounts_array_name[@]}-1; i>=0; i-- )); do
        local m="${mounts_array_name[$i]}"
        if [[ "$(</proc/mounts)" == *" ${m} "* ]]; then
            log_debug "Unmounting ${m}"
            umount --recursive "${m}" || exit_code="${?}"
        fi
    done

    mounts_array_name=()
    if (( exit_code != 0 )); then
        log_error "Error unmounting one or more filesystems"
        return "${exit_code}"
    fi
}

managed_cleanup_all() {
    local exit_code="${?}"
    local i
    for (( i=${#_registered_mount_arrays[@]}-1; i>=0; i-- )); do
        managed_unmount_all "${_registered_mount_arrays[$i]}" || true
    done
    exit "${exit_code}"
}
trap managed_cleanup_all "EXIT"

# === Ebuild Repositories ===

load_ebuild_repositories() {
    if [[ -v repo_entries ]]; then
        return
    fi

    local repo_entry
    while IFS= read -r repo_entry; do
        if [[ -z "${repo_entry}" ]]; then continue; fi

        repo_entries+=("${repo_entry}")
    done <<< "${REPOS}"
}

download_ebuild_repositories() {
    log_info "Downloading ebuild repositories"

    load_ebuild_repositories

    for repo_entry in "${repo_entries[@]}"; do
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
        log_info "Verifying latest commit signature for ${repo_name} in ${repo_dir}"
        git -C "${repo_dir}" verify-commit HEAD
    done
}

configure_ebuild_repositories() {
    local target_root="${1}"
    log_info "Configuring ebuild repositories for ${target_root}"

    load_ebuild_repositories

    local repos_conf_dir="${target_root}/etc/portage/repos.conf"
    create_directory "${repos_conf_dir}"

    for repo_entry in "${repo_entries[@]}"; do
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
    local target_root="${1}"
    log_info "Mounting ebuild repositories for ${target_root}"

    load_ebuild_repositories

    local repos_dir="${target_root}/var/db/repos"
    create_directory "${repos_dir}"

    for repo_entry in "${repo_entries[@]}"; do
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

import_gentoo_release_keys() {
    if (( ${_GENTOO_KEYS_IMPORTED:-0} )); then
        return
    fi

    local gentoo_release_keys_file="${WORK_DIR}/keys/gentoo-release.asc"
    log_info "Importing Gentoo release keys"
    gpg --quiet --import "$gentoo_release_keys_file"

    gpg --with-colons --show-keys "$gentoo_release_keys_file" | \
        awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
        gpg --batch --import-ownertrust --quiet

    readonly _GENTOO_KEYS_IMPORTED=1
}

import_public_keys() {
    if [[ -v public_keys_imported ]]; then
        return
    fi

    log_info "Importing public keys"

    gpg --import --quiet <<< "${PUBLIC_KEYS}"

    gpg --show-keys --with-colons <<< "${PUBLIC_KEYS}" | \
        awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
        gpg --batch --import-ownertrust --quiet

    readonly public_keys_imported=1
}

# === Portage Configuration ===

remove_portage_configuration() {
    local target_root="${1}"
    log_info "Removing Portage configuration for ${target_root}"

    find "${target_root}/etc/portage" -mindepth 1 -maxdepth 1 -exec rm --force \
        --recursive {} +
}

configure_portage() {
    local target_root="${1}"
    local profile="${2}"
    local portage_conf_name="${3}"
    log_info "Applying Portage configuration for ${target_root}"

    local portage_conf_dir="${target_root}/etc/portage"
    create_directory "${portage_conf_dir}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local portage_conf_profile_dir="${portage_conf_dir}/make.profile"
    local relative_repo_profile_dir="../../var/db/repos/${repo}/profiles/${repo_profile}"
    create_symbolic_link "${relative_repo_profile_dir}" \
        "${portage_conf_profile_dir}"

    recursive_copy "${WORK_DIR}/portage/${portage_conf_name}/." \
        "${portage_conf_dir}"

    configure_ebuild_repositories "${target_root}"

    if [[ -z "${target_root}" ]]; then
        if command -v getuto >/dev/null 2>&1; then
            getuto
        else
            log_warn "getuto command not found on host, skipping..."
        fi
    else
        chroot_run "${target_root}" "getuto"
    fi

    local portage_gnupg_dir="${target_root}/etc/portage/gnupg"
    create_directory "${portage_gnupg_dir}"
    chmod "0700" "${portage_gnupg_dir}"

    if [[ -n "${SIGNING_KEY:-}" ]]; then
        if declare -F import_signing_key >/dev/null; then
            import_signing_key
            gpg --batch --export "${signing_key_fingerprint}" | \
                gpg --batch --homedir "${portage_gnupg_dir}" --import

            echo "${signing_key_fingerprint}:6:" | \
                gpg --batch --homedir "${portage_gnupg_dir}" \
                --import-ownertrust --quiet
        fi
    elif [[ -n "${PUBLIC_KEYS:-}" ]]; then
        import_public_keys
        gpg --batch --export | \
            gpg --batch --homedir "${portage_gnupg_dir}" --import

        gpg --batch --homedir "${portage_gnupg_dir}" --list-keys --with-colons 2>/dev/null | \
            awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
            gpg --batch --homedir "${portage_gnupg_dir}" --import-ownertrust --quiet
    fi

    gpg --batch --check-trustdb --homedir "${portage_gnupg_dir}" 2>/dev/null || true

    # Mask check-chroot plugin to allow kernel-install in chroot
    create_directory "${target_root}/etc/kernel/install.d"
    create_symbolic_link "/dev/null" \
        "${target_root}/etc/kernel/install.d/05-check-chroot.install"
}

load_binpkg_repositories() {
    if [[ -v binpkg_repo_entries ]]; then
        return
    fi

    local repo_entry
    while IFS= read -r repo_entry; do
        if [[ -z "${repo_entry}" ]]; then continue; fi

        binpkg_repo_entries+=("${repo_entry}")
    done <<< "${BINPKG_REPOS}"
}

configure_portage_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    log_info "Configuring Portage binary packages for ${target_root}"

    load_binpkg_repositories

    local repo_dir="${target_root}/etc/portage/binrepos.conf"
    create_directory "${repo_dir}"

    local repo repo_profile
    IFS=" " read -r repo repo_profile < <(parse_profile "${profile}")

    local repo_entry
    for repo_entry in "${binpkg_repo_entries[@]}"; do
        local repo_name repo_url
        IFS=" " read -r repo_name repo_url < <(echo "${repo_entry}")

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

    create_empty_file "${target_root}/etc/resolv.conf"
    managed_mount "_active_chroot_mounts" --bind --options "ro" \
        "/etc/resolv.conf" "${target_root}/etc/resolv.conf"

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

kill_chroot_processes() {
    local target_root
    target_root="$(realpath "${1}")"
    if [[ -z "${target_root}" || "${target_root}" == "/" ]]; then
        return
    fi

    local p
    local root_link
    for p in /proc/[0-9]*; do
        if [[ -d "$p" ]] && root_link="$(readlink "$p/root" 2>/dev/null)"; then
            if [[ "$root_link" == "$target_root" ]]; then
                log_warn "Killing lingering chroot process ${p##*/}"
                kill -9 "${p##*/}" 2>/dev/null || true
            fi
        fi
    done
}

chroot_run() {
    local target_root="${1}"
    log_info "Running command in chroot for ${target_root}"

    mount_chroot_filesystems "${target_root}"

    shift

    local exit_code="0"
    chroot "${target_root}" /usr/bin/bash --login -e -c "${*}" || \
        exit_code="${?}"

    kill_chroot_processes "${target_root}"
    unmount_chroot_filesystems

    return "${exit_code}"
}
