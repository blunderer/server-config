# shellcheck shell=bash
# box link subcommand (sourced by box).

# box link [DATA_DIR]: srv and box in /usr/local/bin; then, when missing,
# /etc/srv/hosts.env (the inventory) and /etc/srv/host.env (this host's file,
# chosen among DATA_DIR/configs/*.env) as links into the data folder. Existing
# files in /etc/srv are never replaced.
cmd_link() {
	need_root
	say "commands in /usr/local/bin"
	ln -sfn "$SRV" /usr/local/bin/srv
	ln -sfn "$REPO/box" /usr/local/bin/box
	ln -sfn "$REPO/remote" /usr/local/bin/remote
	ok "srv, box -> $REPO"

	local data configs
	data=$(link_data_dir "${1:-}")
	configs=$data/configs
	say "host env in /etc/srv (from $configs)"
	mkdir -p /etc/srv
	if [[ -e /etc/srv/hosts.env || -L /etc/srv/hosts.env ]]; then
		ok "/etc/srv/hosts.env exists ($(readlink -f /etc/srv/hosts.env)): left as is"
	elif [[ -f $configs/hosts.env ]]; then
		ln -s "$configs/hosts.env" /etc/srv/hosts.env
		ok "/etc/srv/hosts.env -> $configs/hosts.env"
	else
		warn "no inventory $configs/hosts.env (copy the data folder first, or: box link DATA_DIR)"
	fi

	if [[ -e $SRV_HOST_ENV || -L $SRV_HOST_ENV ]]; then
		ok "$SRV_HOST_ENV exists ($(readlink -f "$SRV_HOST_ENV")): left as is"
		return 0
	fi
	local -a files=()
	local f
	for f in "$configs"/*.env; do
		[[ -f $f && $(basename "$f") != hosts.env ]] && files+=("$f")
	done
	if ((${#files[@]} == 0)); then
		warn "no host file in $configs (cp examples/example.env $configs/<host>.env, then box link again)"
		return 0
	fi
	local choice='' def='' i
	for i in "${!files[@]}"; do
		[[ $(basename "${files[i]}" .env) == "$(hostname -s)" ]] && def=$((i + 1))
	done
	if [[ -t 0 ]]; then
		echo "  Which file is this host's ($SRV_HOST_ENV)?"
		for i in "${!files[@]}"; do
			printf '    %d) %s%s\n' $((i + 1)) "${files[i]}" "$([[ $((i + 1)) == "$def" ]] && echo '   (matches the hostname)')"
		done
		read -r -p "  Number${def:+ [$def]}, empty to skip: " choice
		choice=${choice:-$def}
	elif [[ -n $def ]]; then
		choice=$def   # not interactive: only the obvious one
	fi
	if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#files[@]})); then
		ln -s "${files[choice - 1]}" "$SRV_HOST_ENV"
		ok "$SRV_HOST_ENV -> ${files[choice - 1]}"
	else
		warn "$SRV_HOST_ENV not linked: box link again, or ln -s $configs/<host>.env $SRV_HOST_ENV"
	fi
}
