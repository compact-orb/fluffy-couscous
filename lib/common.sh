shopt -s extglob

work_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
build_dir="${work_dir}/build"
project_repos_dir="${build_dir}/repos"
gentoo_mirror_url="http://gentoo.mirrors.ovh.net/gentoo-distfiles"

env_file="$(${work_dir}/.env)"
if [[ -f "$env_file" ]]; then
    source "$env_file"
fi

create_directory() {
    echo "Creating ${1}"
    mkdir --parents "${1}"
}

remove_directory() {
    echo "Removing ${1}"
    rmdir "${1}"
}

remove_file() {
    echo "Removing ${1}"
    rm "${1}"
}

force_remove() {
    echo "Force removing ${1}"
    rm --force --recursive "${1}"
}

recursive_copy() {
    echo "Recursively copying ${1} to ${2}"
    cp --dereference --recursive "${1}" "${2}"
}

load_ebuild_repositories() {
    if [[ -v repo_entries ]]; then
        return
    fi

    while IFS= read -r repo_entry; do
        if [[ -z "${repo_entry}" ]]; then continue; fi

        repo_entries+=("${repo_entry}")
    done <<< "${REPOS}"
}

create_symbolic_link() {
    echo "Creating symbolic link from ${1} to ${2}"
    ln --symbolic "${1}" "${2}"
}

create_empty_file() {
    echo "Creating empty file ${1}"
    > "${1}"
}

create_file() {
    echo "Creating file ${1}"
    echo "${2}" > "${1}"
}

download_ebuild_repositories() {
    echo "Downloading ebuild repositories"

    load_ebuild_repositories

    create_directory "${project_repos_dir}"

    for repo_entry in "${repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local repo_dir="${project_repos_dir}/${repo_name}"
        echo "Cloning ${repo_url} into ${repo_dir}"
        git clone --depth 1 --quiet "${repo_url}" "${repo_dir}"
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
        IFS= read -d "" -r repo_conf_content << "EOF" || true
[${repo_name}]
location = /var/db/repos/${repo_name}
sync-type = git
sync-uri = ${repo_url}
EOF
        printf "%s" "${repo_conf_content}" > "${repo_conf_file}"
    done
}

mount_ebuild_repositories() {
    local target_root="${1}"
    echo "Mounting ebuild repositories for ${target_root}"

    load_ebuild_repositories

    local repos_dir="${target_root}/var/db/repos"
    create_directory "${repos_dir}"

    for repo_entry in "${repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local source_repo_dir="${project_repos_dir}/${repo_name}"
        local target_repo_dir="${repos_dir}/${repo_name}"

        create_directory "${target_repo_dir}"

        echo "Mounting ${source_repo_dir} to ${target_repo_dir}"
        mount --bind "${source_repo_dir}" "${target_repo_dir}"
    done
}

unmount_ebuild_repositories() {
    local target_root="${1}"
    echo "Unmounting ebuild repositories for ${target_root}"

    load_ebuild_repositories

    for repo_entry in "${repo_entries[@]}"; do
        local repo_name
        local repo_url
        IFS=" " read -r repo_name repo_url <<< "${repo_entry}"

        local target_repo_dir="${target_root}/var/db/repos/${repo_name}"

        echo "Unmounting ${target_repo_dir}"
        umount "${target_repo_dir}"

        remove_directory "${target_repo_dir}"
    done
}

import_gentoo_release_keys() {
    if (( ${gentoo_release_keys_imported:-0} )); then
        return
    fi

    local gentoo_release_keys_file="${work_dir}/keys/gentoo-release.asc"
    echo "Importing Gentoo release keys"
    gpg --quiet --import "$gentoo_release_keys_file"

    gpg --with-colons --show-keys "$gentoo_release_keys_file" | \
        awk --field-separator=":" '/^fpr/ {print $10 ":6:"}' | \
        gpg --import-ownertrust --quiet

    gentoo_release_keys_imported=1
}

download_extract_latest_gentoo_autobuild() {
    local output_dir="${1}"
    local architecture="${2}"
    local name="${3}"

    echo "Downloading and extracting latest ${name} to ${output_dir}"

    import_gentoo_release_keys

    create_directory "${output_dir}"

    local latest_autobuild_relative_path=$(curl --silent \
        "${gentoo_mirror_url}/releases/${architecture}/autobuilds/latest-${name}.txt" |
        gpg --decrypt --quiet | awk '!/^#/ {print $1; exit}')

    local latest_autobuild_path="${gentoo_mirror_url}/releases/${architecture}/autobuilds/${latest_autobuild_relative_path}"

    local download_dir="/tmp"

    local downloaded_latest_autobuild_file="${download_dir}/$(basename "${latest_autobuild_relative_path}")"

    echo "Downloading to ${downloaded_latest_autobuild_file} and ${downloaded_latest_autobuild_file}.asc"
    aria2c --file-allocation="none" --force-sequential \
        --max-concurrent-downloads="4" --max-connection-per-server="4" \
        --max-tries="3" --output-dir="${download_dir}" --quiet \
        "${latest_autobuild_path}" "${latest_autobuild_path}.asc"

    echo "Verifying ${downloaded_latest_autobuild_file}"
    gpg --verify "${downloaded_latest_autobuild_file}.asc" \
        "${downloaded_latest_autobuild_file}"

    remove_file "${downloaded_latest_autobuild_file}.asc"

    echo "Extracting ${downloaded_latest_autobuild_file} to ${output_dir}"
    tar --directory="${output_dir}" --extract \
        --file="${downloaded_latest_autobuild_file}" --numeric-owner \
        --preserve-permissions --xattrs-include='*.*'

    remove_file "${downloaded_latest_autobuild_file}"
}

remove_portage_configuration() {
    local target_root="${1}"
    echo "Removing Portage configuration for ${target_root}"

    force_remove "${target_root}/etc/portage/*"
}

apply_portage_configuration() {
    local target_root="${1}"
    local profile="${2}"
    local portage_conf_name="${3}"
    echo "Applying Portage configuration for ${target_root}"

    local portage_conf_dir="${target_root}/etc/portage"
    create_directory "${portage_conf_dir}"

    local repo
    local repo_profile
    IFS=":" read -r repo repo_profile <<< "${profile}"

    local portage_conf_profile_dir="${portage_conf_dir}/make.profile"
    local relative_repo_profile_dir="../../var/db/repos/${repo}/profiles/${repo_profile}"
    create_symbolic_link "${relative_repo_profile_dir}" "${portage_conf_profile_dir}"

    recursive_copy "${work_dir}/portage/${portage_conf_name}/*" "${portage_conf_dir}"
}

mount_chroot_filesystems() {
    local target_root="${1}"
    echo "Mounting chroot filesystems for ${target_root}"

    create_empty_file "${target_root}/etc/resolv.conf"
    mount --bind "/etc/resolv.conf" "${target_root}/etc/resolv.conf"

    mount --types "proc" "/proc" "${target_root}/proc"
    mount --rbind "/sys" "${target_root}/sys"
    mount --make-rslave "${target_root}/sys"
    mount --rbind "/dev" "${target_root}/dev"
    mount --make-rslave "${target_root}/dev"
    mount --bind "/run" "${target_root}/run"
    mount --make-slave "${target_root}/run"

    create_directory "${target_root}/var/tmp/portage"
    chown --recursive "250:250" "${target_root}/var/tmp/portage"
    chmod --recursive "775" "${target_root}/var/tmp/portage"
    mount --options "size=50%,uid=250,gid=250,mode=775" --types "tmpfs" \
        "tmpfs" "${target_root}/var/tmp/portage"
}

unmount_chroot_filesystems() {
    local target_root="${1}"
    echo "Unmounting chroot filesystems for ${target_root}"

    umount "${target_root}/var/tmp/portage"

    umount "${target_root}/run"
    umount "${target_root}/dev"
    umount "${target_root}/sys"
    umount "${target_root}/proc"

    umount "${target_root}/etc/resolv.conf"
}
