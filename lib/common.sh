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

load_ebuild_repositories() {
    if [[ -v repo_urls ]]; then
        return
    fi

    repo_urls=("https://github.com/gentoo-mirror/gentoo.git")

    mapfile -t unsanitized_extra_repo_urls <<< "${EXTRA_REPOS}"

    for repo_url in "${unsanitized_extra_repo_urls[@]}"; do
        if [[ -z "${repo_url}" ]]; then continue; fi

        repo_urls+=("${repo_url}")
    done

    unset unsanitized_extra_repo_urls
}

download_ebuild_repositories() {
    echo "Downloading ebuild repositories"

    load_ebuild_repositories

    create_directory "${project_repos_dir}"

    for repo_url in "${repo_urls[@]}"; do
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

    for repo_url in "${repo_urls[@]}"; do
        local repo_name="${repo_url##*/}"; repo_name="${repo_name%.git}"

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

    for repo_url in "${repo_urls[@]}"; do
        local repo_name="${repo_url##*/}"; repo_name="${repo_name%.git}"

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

    for repo_url in "${repo_urls[@]}"; do
        local repo_name="${repo_url##*/}"; repo_name="${repo_name%.git}"

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
    architecture="${1}"
    name="${2}"
    output_dir="${3}"

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
