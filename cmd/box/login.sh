# shellcheck shell=bash
# box login subcommand (sourced by box).

# Authenticate sudo for the duration of the current terminal session (backed by
# /etc/sudoers.d/srv-admin), and with `-s [NAME|PATH]` also load a
# passphrase-protected SSH key from <data>/keys/ssh/id_ecdsa_<name> (default:
# lenderer) into a session-scoped ssh-agent (managed by host/shell/bashrc).
# Cleared automatically on `box logout` or SSH disconnect.
cmd_login() {
	local load_ssh=0 arg="" key
	while (($#)); do
		case $1 in
			-s | --ssh)
				load_ssh=1
				if (($# >= 2)) && [[ ${2:-} != -* ]]; then
					arg=$2
					shift
				fi
				;;
			-h | --help)
				echo "usage: box login [-s [NAME|PATH]]"
				return 0
				;;
			*) die "usage: box login [-s [NAME|PATH]]" ;;
		esac
		shift
	done

	# Cache sudo for this terminal session when not already root.
	if [[ $EUID -ne 0 ]]; then
		sudo -v || die "sudo authentication failed"
		ok "sudo cached for this session (cleared on 'box logout' or disconnect)"
	fi

	((load_ssh)) || return 0

	if [[ -z $arg ]]; then
		arg=$(get admin_ssh_key lenderer 2>/dev/null || echo lenderer)
	fi
	if [[ $arg == */* ]]; then
		key=$arg
	else
		[[ $arg =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid SSH key name '$arg'"
		key="$(ssh_dir)/id_ecdsa_$arg"
	fi

	if [[ -z ${SSH_AUTH_SOCK:-} ]]; then
		die "no ssh-agent in this shell: run 'box shell' and open a new shell (or source ~/.bashrc) so 'box login -s' can manage ssh-agent"
	fi

	# <data>/keys/ssh is root:root 0700; elevate only to read the key into the
	# caller's session-scoped ssh-agent.
	if [[ $EUID -ne 0 && ! -r $key ]]; then
		exec sudo --preserve-env=SSH_AUTH_SOCK "$REPO/box" login -s "$arg"
	fi

	[[ -f $key ]] || die "SSH key not found: $key"

	local mode
	mode=$(stat -c %a "$key" 2>/dev/null || echo 777)
	if (( (8#$mode & 8#077) != 0 )); then
		die "$key permissions are too open ($mode): chmod 600 $key"
	fi

	# Refuse unencrypted keys: a key loaded via box login -s MUST have a passphrase.
	if ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1; then
		die "$key has no passphrase: refusing to load an unencrypted key (encrypt it with: ssh-keygen -p -f $key)"
	fi

	ssh-add "$key" || die "failed to load $key into ssh-agent"
	ok "loaded $key into session ssh-agent (cleared on 'box logout' or disconnect)"
}
