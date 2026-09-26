#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

seed_architecture="${1}"
seed_name="${2}"
profile="${3}"

download_ebuild_repositories

download_extract_latest_gentoo_autobuild "${seed_architecture}" \
    "${seed_name}" "${work_dir}/seed"

# clear portage config

configure_ebuild_repositories "${work_dir}/seed"

mount_ebuild_repositories "${work_dir}/seed"
