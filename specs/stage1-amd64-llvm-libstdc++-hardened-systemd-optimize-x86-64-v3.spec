subarch: amd64
target: stage1
version_stamp: llvm-libstdc++-hardened-systemd-optimize-x86-64-v3
rel_type: automatic-journey
profile: automatic-journey:amd64/llvm-libstdc++-hardened-systemd-optimize-x86-64-v3
snapshot_treeish: current.xz
source_subpath: automatic-journey/latest-stage3-amd64-desktop-systemd
compression_mode: pixz
update_seed: yes
update_seed_command: --update --deep --newuse @world llvm-core/lld
portage_confdir: /fluffy-couscous/portage/stage1
portage_prefix: fluffy-couscous
repos: /var/db/repos/automatic-journey
