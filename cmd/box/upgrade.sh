# shellcheck shell=bash
# box upgrade subcommand (sourced by box).

cmd_upgrade() {
	need_root
	export DEBIAN_FRONTEND=noninteractive
	say "apt upgrade $(date -Is)"
	apt-get update -q
	# --with-new-pkgs: also take upgrades that need a new package (kernels),
	# never removes anything. Changed config files keep the local version.
	apt-get -y -q --with-new-pkgs \
		-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
	apt-get -y -q autoremove
	apt-get clean   # the root partition is small
	if [[ -f /var/run/reboot-required ]]; then
		echo "REBOOT REQUIRED for: $(xargs </var/run/reboot-required.pkgs 2>/dev/null)"
	fi
}
