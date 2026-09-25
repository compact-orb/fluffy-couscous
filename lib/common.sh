shopt -s extglob

work_dir="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
build_dir="${work_dir}/build"
project_repos_dir="${build_dir}/repos"

env_file="$(${work_dir}/.env)"
if [[ -f "$env_file" ]]; then
    source "$env_file"
fi

create_directory() {
    echo "Creating ${1}"
    mkdir --parents "${1}"
}

load_ebuild_repositories() {
    if (( ${#repo_urls[@]} )); then
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

        local repo_conf="${repos_conf_dir}/${repo_name}.conf"
        echo "Creating ${repo_conf}"
        local repo_conf_content
        IFS= read -d "" -r repo_conf_content << "EOF" || true
[${repo_name}]
location = /var/db/repos/${repo_name}
sync-type = git
sync-uri = ${repo_url}
EOF
        printf "%s" "${repo_conf_content}" > "${repo_conf}"
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

        echo "Removing ${target_repo_dir}"
        rmdir "${target_repo_dir}"
    done
}
