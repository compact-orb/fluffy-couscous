# Remove the env loading block from its current location
sed -i '/env_file="${WORK_DIR}\/.env"/,+3d' lib/common.sh

# Insert it right after WORK_DIR is defined
sed -i '/readonly WORK_DIR=/a \
env_file="${WORK_DIR}/.env"\
if [[ -f "$env_file" ]]; then\
    source "$env_file"\
fi' lib/common.sh

# Put the fallback back for GENTOO_MIRROR_URL
sed -i 's/readonly GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL}"/readonly GENTOO_MIRROR_URL="${GENTOO_MIRROR_URL:-"http:\/\/distfiles.gentoo.org"}"/g' lib/common.sh
