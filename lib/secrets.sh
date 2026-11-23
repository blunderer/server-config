# shellcheck shell=bash
# Podman secrets synchronization and inspection helpers (sourced lazily by box).

keys_data() { get data_dir /home/data; }

websso_val() {
	[[ -f $2 ]] || return 0
	sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" "$2" 2>/dev/null | head -n 1
}

# ------------------------------------------------------------ podman secrets

keys_podman_user() { get unix_role; }

keys_has_podman() {
	command -v podman >/dev/null 2>&1 && id "$(keys_podman_user)" >/dev/null 2>&1
}

# keys_as_user CMD...: delegate to shared rt_as_podman_user from lib/runtime.sh.
keys_as_user() { SRV_PODMAN_USER=$(keys_podman_user) rt_as_podman_user "$@"; }
keys_pctl() { SRV_PODMAN_USER=$(keys_podman_user) rt_podman "$@"; }
keys_uctl() { SRV_PODMAN_USER=$(keys_podman_user) rt_uctl "$@"; }

keys_secret_state_file() {
	echo "${SRV_PODMAN_SECRETS_STATE:-/var/lib/srv-host/podman-secrets}"
}

# keys_dkim_secret_name FOLDER SELECTOR: deterministic Podman secret name for a DKIM key.
keys_dkim_secret_name() {
	printf 'srv-dkim-%s--%s\n' "$1" "$2"
}

# keys_podman_entries: tab-separated "SECRET_NAME<TAB>FILE<TAB>SERVICES_CSV"
# for every secret managed by box keys or service prepare hooks.
keys_podman_entries() {
	local d data f rel folder sel
	data=$(keys_data)
	d=$(get domain blunderer.org)
	printf '%s\t%s\t%s\n' "srv-ssl-cert" "$data/keys/ssl/$d/fullchain.crt" "web,mail"
	printf '%s\t%s\t%s\n' "srv-ssl-key" "$data/keys/ssl/$d/$d.key" "web,mail"
	printf '%s\t%s\t%s\n' "srv-websso-cfg" "$data/keys/websso/oauth2.cfg" "web"
	printf '%s\t%s\t%s\n' "srv-db-root-password" "$data/keys/mariadb/root_password" "db"
	printf '%s\t%s\t%s\n' "srv-srs-secret" "$data/keys/postsrsd/postsrsd.secret" "mail"
	printf '%s\t%s\t%s\n' "srv-tsig-acme" "$data/keys/acme/tsig.key" "dns"
	printf '%s\t%s\t%s\n' "srv-tsig-smtp" "$data/keys/dns/smtp-tsig.key" "dns"
	printf '%s\t%s\t%s\n' "srv-tsig-xfer" "$data/keys/dns/xfer-tsig.key" "dns"
	for f in "$data/keys/opendkim"/*/*.private; do
		[[ -e $f ]] || continue
		rel=${f#"$data/keys/opendkim/"}
		folder=${rel%%/*}
		sel=$(basename "$f" .private)
		printf '%s\t%s\t%s\n' "$(keys_dkim_secret_name "$folder" "$sel")" "$f" "mail"
	done
}

keys_is_managed_secret() {
	case $1 in
		srv-ssl-cert | srv-ssl-key | srv-websso-cfg | srv-db-root-password | \
		srv-srs-secret | srv-tsig-acme | srv-tsig-smtp | srv-tsig-xfer | \
		srv-dkim-*--*) return 0 ;;
		*) return 1 ;;
	esac
}

keys_state_get() {
	local sf name
	sf=$(keys_secret_state_file)
	name=$1
	[[ -f $sf ]] || return 0
	awk -v n="$name" '$1 == n { print $2; exit }' "$sf"
}

keys_state_set() {
	local sf=$1 name=$2 hash=$3 file=$4 dir tmp
	dir=$(dirname "$sf")
	mkdir -p "$dir"
	tmp=$(mktemp "$dir/.podman-secrets.XXXXXX")
	chmod 0600 "$tmp"
	if [[ -f $sf ]]; then
		awk -v n="$name" '$1 != n' "$sf" >"$tmp" || { rm -f "$tmp"; return 1; }
	fi
	printf '%s %s %s\n' "$name" "$hash" "$file" >>"$tmp" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$sf"
}

keys_state_del() {
	local sf=$1 name=$2 dir tmp
	[[ -f $sf ]] || return 0
	dir=$(dirname "$sf")
	tmp=$(mktemp "$dir/.podman-secrets.XXXXXX")
	chmod 0600 "$tmp"
	awk -v n="$name" '$1 != n' "$sf" >"$tmp" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$sf"
}

keys_podman_existing() {
	keys_pctl secret ls --format '{{.Name}}' 2>/dev/null || true
}

keys_podman_service_running() {
	local s=$1 rdir
	rdir=${SRV_STATE:-${SRV_RELEASES_DIR:-/srv/releases}}
	[[ -d $rdir/$s/current/quadlet ]] || return 1
	if [[ ${SRV_PODMAN_NO_SYSTEMD:-0} != 1 ]] && command -v systemctl >/dev/null 2>&1; then
		local active
		active=$(keys_uctl list-units --state=active --plain --no-legend "srv-${s}*.service" 2>/dev/null || true)
		[[ -n $active ]] && return 0
		return 1
	fi
	return 0
}

# keys_secret_status NAME FILE: short Podman secret state for `box keys list`.
keys_secret_status() {
	local name=$1 file=$2 existing rec hash
	keys_has_podman || return 0
	[[ -s $file ]] || return 0
	existing=${KEYS_EXISTING_SECRETS:-$(keys_podman_existing)}
	if ! grep -qxF "$name" <<<"$existing"; then
		echo "; podman secret missing (box keys sync)"
		return 0
	fi
	rec=$(keys_state_get "$name")
	hash=$(sha256sum "$file" | awk '{print $1}')
	if [[ -z $rec || $rec != "$hash" ]]; then
		echo "; podman secret stale (box keys sync)"
	else
		echo "; podman secret ok"
	fi
}

# keys_podman_drift: print one line per Podman secret out of sync with disk.
keys_podman_drift() {
	keys_has_podman || return 0
	local existing sf name file _ hash rec
	existing=$(keys_podman_existing)
	sf=$(keys_secret_state_file)
	declare -A active_names=()
	while IFS=$'\t' read -r name file _; do
		[[ -n $name ]] || continue
		if [[ -s $file ]]; then
			active_names[$name]=1
			if ! grep -qxF "$name" <<<"$existing"; then
				echo "missing $name $file"
				continue
			fi
			rec=$(keys_state_get "$name")
			hash=$(sha256sum "$file" | awk '{print $1}')
			[[ $rec == "$hash" ]] || echo "stale $name $file"
		fi
	done < <(keys_podman_entries)
	while IFS= read -r name; do
		[[ -n $name ]] || continue
		keys_is_managed_secret "$name" || continue
		[[ -n ${active_names[$name]:-} ]] || echo "orphaned $name -"
	done <<<"$existing"
}

# keys_podman_sync [--restart] [--quiet]: create/replace Podman secrets for all
# key files present on disk, remove deleted managed secrets, and either restart
# running Podman services using replaced secrets or remind the operator.
# shellcheck disable=SC2120 # called with --restart/--quiet from box keys sync
keys_podman_sync() {
	local restart=0 quiet=0 arg
	for arg in "$@"; do
		case $arg in
			--restart) restart=1 ;;
			--quiet) quiet=1 ;;
			*) die "box keys sync: unknown option $arg" ;;
		esac
	done
	if ! keys_has_podman; then
		((quiet)) && return 0
		die "podman is not installed or $(keys_podman_user) does not exist (run box packages && box podman)"
	fi
	local sf existing name file svcs hash rec s had_secret changed=0
	local -A active_names=() restart_map=()
	sf=$(keys_secret_state_file)
	existing=$(keys_pctl secret ls --format '{{.Name}}') || return 1

	while IFS=$'\t' read -r name file svcs; do
		[[ -n $name ]] || continue
		[[ -s $file ]] || continue
		active_names[$name]=1
		hash=$(sha256sum "$file" | awk '{print $1}')
		rec=$(keys_state_get "$name")
		if grep -qxF "$name" <<<"$existing"; then
			had_secret=1
		else
			had_secret=0
		fi
		if ((had_secret)) && [[ $rec == "$hash" ]]; then
			continue
		fi
		if ((had_secret)); then
			keys_pctl secret create --replace "$name" - <"$file" >/dev/null || return 1
		else
			keys_pctl secret create "$name" - <"$file" >/dev/null || return 1
		fi
		keys_state_set "$sf" "$name" "$hash" "$file"
		changed=$((changed + 1))
		if ((had_secret)); then
			((quiet)) || ok "podman secret $name: replaced ($file)"
		else
			((quiet)) || ok "podman secret $name: created ($file)"
		fi
		# A replaced secret (or newly created DKIM key) requires a container restart
		# for running Podman services to see the new /run/secrets file.
		IFS=',' read -r -a _svcs <<<"$svcs"
		for s in "${_svcs[@]}"; do
			[[ -n $s ]] && restart_map[$s]=1
		done
	done < <(keys_podman_entries)

	while IFS= read -r name; do
		[[ -n $name ]] || continue
		keys_is_managed_secret "$name" || continue
		if [[ -z ${active_names[$name]:-} ]]; then
			keys_pctl secret rm "$name" >/dev/null || return 1
			keys_state_del "$sf" "$name"
			changed=$((changed + 1))
			((quiet)) || ok "podman secret $name: removed"
		fi
	done <<<"$existing"

	local enabled to_restart=()
	enabled=" $(get services '') "
	for s in "${!restart_map[@]}"; do
		[[ $enabled == *" $s "* ]] || continue
		keys_podman_service_running "$s" || continue
		to_restart+=("$s")
	done

	if ((${#to_restart[@]} > 0)); then
		mapfile -t to_restart < <(printf '%s\n' "${to_restart[@]}" | sort)
		if ((restart)); then
			for s in "${to_restart[@]}"; do
				"$SRV" restart "$s" >/dev/null
				ok "$s: restarted (loaded updated Podman secret)"
			done
		else
			warn "Podman secret(s) updated for running quadlet(s): ${to_restart[*]}"
			for s in "${to_restart[@]}"; do
				echo "  Restart needed: srv restart $s"
			done
		fi
	elif ((changed == 0 && !quiet)); then
		ok "podman secrets: all up to date"
	fi
}

keys_auto_sync() {
	keys_has_podman || return 0
	# shellcheck disable=SC2119 # intentional no-arg sync
	keys_podman_sync || warn "could not sync Podman secrets (run box keys sync)"
}
