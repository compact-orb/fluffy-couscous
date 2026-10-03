# Caller scripts (like bootstrap.sh) declare a required_commands=() array first,
# and then source this file. This += appends these base requirements to the
# caller's array. The caller can then add its own specifics.
required_commands+=(
    "aria2c"
    "awk"
    "chroot"
    "curl"
    "fusermount3"
    "git"
    "gpg"
    "mount"
    "mountpoint"
    "rclone"
    "tar"
    "umount"
    "zstd"
)
readonly WORK_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly LOCAL_REPOS_DIR="${BUILD_DIR}/repos"
readonly GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL:-"http://distfiles.gentoo.org"}"
readonly PORTAGE_GPG_DIR="/var/lib/portage/gnupg-sign"
readonly PORTAGE_SECUREBOOT_DIR="/var/lib/portage/secureboot"

env_file="${WORK_DIR}/.env"
if [[ -f "$env_file" ]]; then
    source "$env_file"
fi

# === Command Requirements ===

check_required_commands() {
    local missing_commands=()
    local -A seen=()
    for command in "${required_commands[@]}"; do
        if [[ -v seen["$command"] ]]; then
            continue
        fi
        seen["$command"]=1

        if ! command -v "${command}" > "/dev/null" 2>&1; then
            missing_commands+=("${command}")
        fi
    done

    if (( ${#missing_commands[@]} > 0)); then
        printf "Missing required commands:"
        printf " %s" "${missing_commands[@]}"
        printf "\n"
        exit 1
    fi
}

# === File and Directory Helpers ===

create_directory() {
    if [[ -d "${1}" ]]; then
        return
    fi
    echo "Creating ${1}"
    mkdir --parents "${1}"
}


remove_file() {
    echo "Removing ${1}"
    rm "${1}"
}

force_remove() {
    echo "Force removing ${1}"
    rm --force --recursive "${1}"
}

copy_file() {
    echo "Copying ${1} to ${2}"
    cp --dereference "${1}" "${2}"
}

recursive_copy() {
    echo "Recursively copying ${1} to ${2}"
    cp --dereference --recursive "${1}" "${2}"
}

create_empty_file() {
    echo "Creating empty file ${1}"
    > "${1}"
}

create_file() {
    echo "Creating file ${1}"
    printf "%s\n" "${2}" > "${1}"
}

create_symbolic_link() {
    echo "Creating symbolic link from ${1} to ${2}"
    ln --symbolic "${1}" "${2}"
}

s3_rclone() {
    rclone --s3-provider "Other" --s3-access-key-id "${S3_ACCESS_KEY_ID}" \
        --s3-secret-access-key "${S3_SECRET_ACCESS_KEY}" \
        --s3-region "${S3_REGION}" --s3-endpoint "${S3_ENDPOINT}" -v \
        "${@}"
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

    echo "Mounting ${target}"
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
        if mountpoint --quiet "${m}"; then
            echo "Unmounting ${m}"
            umount --recursive "${m}" || exit_code="${?}"
        fi
    done

    mounts_array_name=()
    if (( exit_code != 0 )); then
        echo "Error unmounting one or more filesystems"
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
    echo "Downloading ebuild repositories"

    load_ebuild_repositories

    import_gentoo_release_keys
    # TODO: import git pubic keys

    create_directory "${LOCAL_REPOS_DIR}"

    for repo_entry in "${repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local repo_dir="${LOCAL_REPOS_DIR}/${repo_name}"
        if [[ -d "${repo_dir}" ]]; then
            echo "Updating ${repo_name} in ${repo_dir}"
            git -C "${repo_dir}" fetch --depth 1 origin
            git -C "${repo_dir}" reset --hard FETCH_HEAD
        else
            echo "Cloning ${repo_url} into ${repo_dir}"
            git clone --depth 1 --quiet "${repo_url}" "${repo_dir}"
        fi
        # echo "Verifying latest commit signature for ${repo_name} in ${repo_dir}"
        # git -C "${repo_dir}" verify-commit HEAD
    done
}

configure_ebuild_repositories() {
    local target_root="${1}"
    echo "Configuring ebuild repositories for ${target_root}"

    load_ebuild_repositories

    local repos_conf_dir="${target_root}/etc/portage/repos.conf"
    create_directory "${repos_conf_dir}"

    for repo_entry in "${repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local repo_conf_file="${repos_conf_dir}/${repo_name}.conf"
        echo "Creating ${repo_conf_file}"
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
mount_repos_in_chroot() {
    local target_root="${1}"
    echo "Mounting ebuild repositories for ${target_root}"

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

        echo "Mounting ${source_repo_dir} to ${target_repo_dir}"
        managed_mount "_active_repo_mounts" --bind --options "ro" \
            "${source_repo_dir}" "${target_repo_dir}"
    done
}

unmount_repos_in_chroot() {
    echo "Unmounting ebuild repositories"
    managed_unmount_all "_active_repo_mounts"
}

# === GPG and Security ===

import_gentoo_release_keys() {
    if (( ${_GENTOO_KEYS_IMPORTED:-0} )); then
        return
    fi

    local gentoo_release_keys_file="${WORK_DIR}/keys/gentoo-release.asc"
    echo "Importing Gentoo release keys"
    gpg --quiet --import "$gentoo_release_keys_file"

    gpg --with-colons --show-keys "$gentoo_release_keys_file" | \
        awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
        gpg --import-ownertrust --quiet

    readonly _GENTOO_KEYS_IMPORTED=1
}

# === Stage Downloading and Extraction ===

fetch_seed_stage() {
    local output_dir="${1}"
    local architecture="${2}"
    local name="${3}"

    echo "Downloading and extracting latest ${name} to ${output_dir}"

    import_gentoo_release_keys

    create_directory "${output_dir}"

    local seed_path
    seed_path=$(curl --silent \
        "${GENTOO_MIRROR_URL}/releases/${architecture}/autobuilds/latest-${name}.txt" |
        gpg --decrypt --quiet | awk '!/^#/ && NF {print $1; exit}')

    local latest_autobuild_path="${GENTOO_MIRROR_URL}/releases/${architecture}/autobuilds/${seed_path}"

    local download_dir
    download_dir="$(mktemp --directory)"

    local seed_tarball="${download_dir}/$(basename "${seed_path}")"

    echo "Downloading to ${seed_tarball} and ${seed_tarball}.asc"
    aria2c --file-allocation="none" --force-sequential \
        --max-concurrent-downloads="4" --max-connection-per-server="4" \
        --max-tries="3" --dir="${download_dir}" --quiet \
        "${latest_autobuild_path}" "${latest_autobuild_path}.asc"

    echo "Verifying ${seed_tarball}"
    gpg --verify "${seed_tarball}.asc" \
        "${seed_tarball}"

    remove_file "${seed_tarball}.asc"

    echo "Extracting ${seed_tarball} to ${output_dir}"
    tar --directory="${output_dir}" --extract \
        --file="${seed_tarball}" --numeric-owner \
        --preserve-permissions --xattrs-include='*.*'

    remove_file "${seed_tarball}"
    force_remove "${download_dir}"
}

# === Portage Configuration ===

remove_portage_configuration() {
    local target_root="${1}"
    echo "Removing Portage configuration for ${target_root}"

    find "${target_root}/etc/portage" -mindepth 1 -maxdepth 1 -exec rm --force \
        --recursive {} +
}

configure_portage() {
    local target_root="${1}"
    local profile="${2}"
    local portage_conf_name="${3}"
    echo "Applying Portage configuration for ${target_root}"

    import_signing_key

    local portage_conf_dir="${target_root}/etc/portage"
    create_directory "${portage_conf_dir}"

    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")

    local portage_conf_profile_dir="${portage_conf_dir}/make.profile"
    local relative_repo_profile_dir="../../var/db/repos/${repo}/profiles/${repo_profile}"
    create_symbolic_link "${relative_repo_profile_dir}" \
        "${portage_conf_profile_dir}"

    recursive_copy "${WORK_DIR}/portage/${portage_conf_name}/." \
        "${portage_conf_dir}"

    configure_ebuild_repositories "${target_root}"

    chroot_run "${target_root}" "getuto"

    gpg --batch --export "${signing_key_fingerprint}" | \
        gpg --batch --homedir "${target_root}/etc/portage/gnupg" --import

    echo "${signing_key_fingerprint}:6:" | \
        gpg --batch --homedir "${target_root}/etc/portage/gnupg" \
        --import-ownertrust --quiet

    gpg --batch --check-trustdb --homedir "${target_root}/etc/portage/gnupg" 
}

# === Chroot Environment ===

_active_chroot_mounts=()
mount_chroot_filesystems() {
    local target_root="${1}"
    echo "Mounting chroot filesystems for ${target_root}"

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
    echo "Unmounting chroot filesystems"
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
        if [[ -d "$p" ]] && root_link=$(readlink "$p/root" 2>/dev/null); then
            if [[ "$root_link" == "$target_root" ]]; then
                echo "Killing lingering chroot process ${p##*/}"
                kill -9 "${p##*/}" 2>/dev/null || true
            fi
        fi
    done
}

chroot_run() {
    local target_root="${1}"
    echo "Running command in chroot for ${target_root}"

    mount_chroot_filesystems "${target_root}"

    shift

    local exit_code="0"
    chroot "${target_root}" /usr/bin/bash --login -e -c "${*}" || \
        exit_code="${?}"

    kill_chroot_processes "${target_root}"
    unmount_chroot_filesystems

    return "${exit_code}"
}

import_signing_key() {
    if [[ -v signing_key_fingerprint ]]; then
        return
    fi

    echo "Importing PGP signing key"

    signing_key_fingerprint=$(gpg --show-keys --with-colons \
        <<< "${SIGNING_KEY}" | awk --field-separator=":" '/^fpr/ {print $10}')

    gpg --import --quiet <<< "${SIGNING_KEY}"
    
    echo "${signing_key_fingerprint}:6:" | \
        gpg --batch --import-ownertrust --quiet
}

install_portage_gpg_key() {
    local target_root="${1}"
    echo "Applying Portage signing key for ${target_root}"

    import_signing_key

    local portage_gnupg_signing_dir="${target_root}${PORTAGE_GPG_DIR}"
    create_directory "${portage_gnupg_signing_dir}"
    chmod "0700" "${portage_gnupg_signing_dir}"

    gpg --batch --export-secret-keys "${signing_key_fingerprint}" | \
        gpg --batch --homedir "${portage_gnupg_signing_dir}" --import

    echo "BINPKG_GPG_SIGNING_KEY=\"${signing_key_fingerprint}\"" \
        >> "${target_root}/etc/portage/make.conf"
}

install_secureboot_keys() {
    local target_root="${1}"
    
    if [[ ! -v SECUREBOOT_KEY ]] || [[ ! -v SECUREBOOT_CERT ]]; then
        return
    fi
    
    echo "Applying Secure Boot keys for ${target_root}"
    
    local secureboot_dir="${target_root}${PORTAGE_SECUREBOOT_DIR}"
    create_directory "${secureboot_dir}"
    chmod "0700" "${secureboot_dir}"
    
    create_file "${secureboot_dir}/db.key" "${SECUREBOOT_KEY}"
    chmod "0600" "${secureboot_dir}/db.key"
    
    create_file "${secureboot_dir}/db.pem" "${SECUREBOOT_CERT}"
    chmod "0644" "${secureboot_dir}/db.pem"
}

# === Uploading ===

upload_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    echo "Uploading binary packages from ${target_root}"

    local portage_binpkgs_dir="${target_root}/var/cache/binpkgs"
    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")
    s3_rclone copy "${portage_binpkgs_dir}" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}"
}

publish_stage_archive() {
    local target_root="${1}"
    local profile="${2}"
    local stage_type="${3}"
    echo "Uploading Gentoo ${stage_type} from ${target_root}"

    import_signing_key

    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")
    local profile_name="${repo_profile//\//-}"
    local stage_filename="${stage_type}-${profile_name}.tar.zst"
    local sig_filename="${stage_filename}.sig"
    local archive_dir
    archive_dir="$(mktemp --directory)"
    local stage_file="${archive_dir}/${stage_filename}"
    local sig_file="${archive_dir}/${sig_filename}"
    echo "Creating stage archive ${stage_file}"
    tar --create --file="${stage_file}" --directory="${target_root}" \
        --preserve-permissions --numeric-owner --xattrs-include='*.*' \
        --use-compress-program="zstd -9 -T0 --long=31" \
        --exclude=".${PORTAGE_GPG_DIR}" \
        --exclude=".${PORTAGE_SECUREBOOT_DIR}" \
        --exclude="./etc/machine-id" \
        --exclude="./etc/resolv.conf" \
        --exclude="./root/*" \
        --exclude="./tmp/*" \
        --exclude="./var/cache/*" \
        --exclude="./var/lib/systemd/catalog/database" \
        --exclude="./var/log/*" \
        --exclude="./var/tmp/*" \
        .
    echo "Signing stage archive ${stage_file}"
    gpg --batch --detach-sign --local-user "${signing_key_fingerprint}" \
        "${stage_file}"

    echo "Uploading stage archive ${stage_file}"
    s3_rclone copy "${stage_file}" \
        ":s3:${S3_BUCKET_NAME}"

    echo "Uploading stage archive signature ${sig_file}"
    s3_rclone copy "${sig_file}" \
        ":s3:${S3_BUCKET_NAME}"

    force_remove "${stage_file}"
    force_remove "${sig_file}"
    force_remove "${archive_dir}"
}

fetch_project_stage() {
    local target_root="${1}"
    local profile="${2}"
    local stage_type="${3}"
    echo "Downloading and extracting Gentoo ${stage_type} to ${target_root}"

    import_signing_key

    create_directory "${target_root}"

    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")
    local profile_name="${repo_profile//\//-}"
    local stage_filename="${stage_type}-${profile_name}.tar.zst"
    local sig_filename="${stage_filename}.sig"
    local download_dir
    download_dir="$(mktemp --directory)"
    local stage_file="${download_dir}/${stage_filename}"
    local sig_file="${download_dir}/${sig_filename}"
    echo "Downloading stage archive ${stage_file}"
    s3_rclone copy ":s3:${S3_BUCKET_NAME}/${stage_filename}" \
        "${download_dir}"

    echo "Downloading stage archive signature ${sig_file}"
    s3_rclone copy ":s3:${S3_BUCKET_NAME}/${sig_filename}" \
        "${download_dir}"

    echo "Verifying stage archive ${stage_file}"
    gpg --verify "${sig_file}" "${stage_file}"

    echo "Extracting stage archive ${stage_file} to ${target_root}"
    tar --directory="${target_root}" --extract --file="${stage_file}" \
        --preserve-permissions --numeric-owner --xattrs-include='*.*' \
        --use-compress-program="zstd --long=31"

    force_remove "${stage_file}"
    force_remove "${sig_file}"
    force_remove "${download_dir}"
}

_active_binpkg_mounts=()
mount_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    echo "Mounting binary packages for ${target_root}"

    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")

    local binpkgs_dir="${target_root}/var/cache/binpkgs"

    local lowerdir="${binpkgs_dir}-lower"
    create_directory "${lowerdir}"
    local upperdir="${binpkgs_dir}-upper"
    create_directory "${upperdir}"
    local workdir="${binpkgs_dir}-work"
    create_directory "${workdir}"

    local rc_sock="${binpkgs_dir}-rc.sock"
    echo "Mounting ${lowerdir}"
    s3_rclone mount --attr-timeout "24h" --daemon \
        --dir-cache-time "24h" --poll-interval "0" --read-only \
        --rc --rc-addr "unix://${rc_sock}" --rc-no-auth \
        --vfs-cache-mode "minimal" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}" "${lowerdir}"
    # Manually add rclone mount to the list of mounts to be unmounted later
    _active_binpkg_mounts+=("${lowerdir}")

    echo "Pre-loading metadata for ${lowerdir}"
    rclone rc --no-output --unix-socket "${rc_sock}" "vfs/refresh" \
        "recursive=true"

    create_directory "${binpkgs_dir}"
    managed_mount "_active_binpkg_mounts" --options \
        "lowerdir=${lowerdir},upperdir=${upperdir},workdir=${workdir}" \
        --types "overlay" "overlay" "${binpkgs_dir}"
}

unmount_binary_packages() {
    echo "Unmounting binary packages"
    managed_unmount_all "_active_binpkg_mounts"
}

upload_mounted_binary_packages() {
    local target_root="${1}"
    local profile="${2}"
    echo "Uploading mounted binary packages from ${target_root}"

    local repo repo_profile
    read -r repo repo_profile < <(parse_profile "${profile}")

    local binpkgs_dir="${target_root}/var/cache/binpkgs"

    s3_rclone sync "${binpkgs_dir}" \
        ":s3:${S3_BUCKET_NAME}/binpkgs/${repo_profile}"
}
