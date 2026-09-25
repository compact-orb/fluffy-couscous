#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

source "$(realpath "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh")"

# -------- Set Up Repositories --------

download_ebuild_repositories
