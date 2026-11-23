# shellcheck shell=bash
# box packages subcommand (sourced by box).

cmd_packages() {
	need_root
	need_env
	say "apt: no recommended/suggested packages"
	gen_apt_minimal | install_text /etc/apt/apt.conf.d/99srv-minimal || true

	say "base and Podman packages"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -y -q "${PKG_BASE[@]}" "${PKG_PODMAN[@]}"
	# Keep any installed kernel metapackage and the running kernel manual so apt autoremove never removes them.
	local -a kernels=()
	mapfile -t kernels < <(
		{ dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-*' 2>/dev/null || true; } |
			awk -v cur="linux-image-$(uname -r)" '$2 ~ /^ii/ && ($1 == cur || $1 !~ /^linux-image-[0-9]/) {print $1}'
	)
	((${#kernels[@]} == 0)) || apt-mark manual "${kernels[@]}" >/dev/null

	say "tmux: prefix Ctrl+S, modern terminal features"
	install_file "$REPO/host/tmux/tmux.conf" /etc/tmux.conf || true

	say "git: vim as the editor, commits as Tristan Lelong"
	install_file "$REPO/host/git/gitconfig" /etc/gitconfig || true

	say "vim: no mouse (the terminal keeps selecting text)"
	install_file "$REPO/host/vim/vimrc.local" /etc/vim/vimrc.local || true

}
