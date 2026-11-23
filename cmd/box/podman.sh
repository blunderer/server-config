# shellcheck shell=bash disable=SC2015 # `test && ok || warn` reporting is intended
# box podman subcommand (sourced by box).

cmd_podman() {
	need_root
	need_env
	command -v podman >/dev/null || die "Podman is not installed: box packages"
	command -v crun >/dev/null || die "crun is not installed: box packages"
	command -v catatonit >/dev/null || die "catatonit is not installed: box packages"

	local pu puid pgid home storage tmp_sc old_gr="" conf_changed=0
	pu=$(unix_role)
	id "$pu" >/dev/null 2>&1 || die "unix_role user '$pu' does not exist"
	puid=$(id -u "$pu")
	pgid=$(id -gn "$pu")
	home=$(getent passwd "$pu" | cut -d: -f6)
	[[ -n $home ]] || die "cannot determine home directory of $pu"

	say "rootless user $pu: subuid/subgid and systemd linger"
	local sub_changed=0
	if ! _subid_ok /etc/subuid "$pu" "$puid"; then
		usermod --add-subuids 100000-165535 "$pu"
		sub_changed=1
	fi
	if ! _subid_ok /etc/subgid "$pu" "$puid"; then
		usermod --add-subgids 100000-165535 "$pu"
		sub_changed=1
	fi
	if [[ $(loginctl show-user "$pu" -p Linger --value 2>/dev/null || true) != yes ]]; then
		loginctl enable-linger "$pu"
		ok "linger enabled for $pu"
	else
		ok "linger already enabled for $pu"
	fi
	systemctl start "user@${puid}.service" >/dev/null 2>&1 || true
	if [[ ! -S /run/user/$puid/bus ]]; then
		systemctl restart "user@${puid}.service" >/dev/null 2>&1 || true
		SRV_PODMAN_USER="$pu" rt_uctl start dbus.socket >/dev/null 2>&1 || true
	fi
	[[ -S /run/user/$puid/bus ]] && ok "user D-Bus socket active (/run/user/$puid/bus)" ||
		warn "user D-Bus socket missing (/run/user/$puid/bus): reboot or check dbus-user-session"

	say "kernel settings: unprivileged ports >= 25, tun module, journald cap"
	if gen_podman_sysctl | install_text /etc/sysctl.d/99-srv-podman.conf; then
		sysctl -p /etc/sysctl.d/99-srv-podman.conf >/dev/null
	fi
	if gen_podman_modules | install_text /etc/modules-load.d/srv-podman.conf; then
		modprobe tun >/dev/null 2>&1 || true
	fi
	if install_file "$REPO/host/journald/srv.conf" /etc/systemd/journald.conf.d/srv.conf; then
		systemctl restart systemd-journald
	fi

	say "podman: journald logging and storage ($pu)"
	install -d -m 0755 /etc/containers/containers.conf.d
	if gen_podman_containers_conf | install_text /etc/containers/containers.conf.d/srv.conf; then
		conf_changed=1
	fi

	storage=$(get podman_storage_dir /home/podman)
	if [[ ! -d $storage ]]; then
		install -d -m 0755 -o "$pu" -g "$pgid" "$storage"
	elif [[ $(stat -c '%u:%g' "$storage") != "${puid}:$(id -g "$pu")" ]]; then
		# Chown only the top directory; never chown -R over subuid-mapped overlay layers.
		chown "$pu:$pgid" "$storage"
	fi
	install -d -m 0755 -o "$pu" -g "$pgid" "$home/.config" "$home/.config/containers"
	tmp_sc=$(mktemp)
	gen_podman_storage_conf >"$tmp_sc"
	if ! cmp -s "$tmp_sc" "$home/.config/containers/storage.conf" 2>/dev/null; then
		old_gr=$(SRV_PODMAN_USER="$pu" rt_podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
		install -m 0644 -o "$pu" -g "$pgid" "$tmp_sc" "$home/.config/containers/storage.conf"
		ok "installed $home/.config/containers/storage.conf (graphroot=$storage)"
		if [[ -n $old_gr && $old_gr != "$storage" && -d $old_gr ]]; then
			warn "previous Podman graphroot existed at $old_gr (images will be re-pulled/rebuilt in $storage)"
		fi
	else
		chown "$pu:$pgid" "$home/.config/containers/storage.conf"
	fi
	rm -f "$tmp_sc"
	local db_updated="" bare_oci=""
	db_updated=$(SRV_PODMAN_USER="$pu" rt_as_podman_user python3 - "$storage" "$home" <<-'PY' || true
	import os, sqlite3, sys
	storage, home = sys.argv[1], sys.argv[2]
	cands = [
	    os.path.join(storage, "db.sql"),
	    os.path.join(storage, "libpod", "db.sql"),
	    os.path.join(home, ".local/share/containers/storage/db.sql"),
	    os.path.join(home, ".local/share/containers/storage/libpod/db.sql"),
	]
	changed = 0
	for p in cands:
	    if not os.path.isfile(p):
	        continue
	    con = sqlite3.connect(p, timeout=5.0)
	    try:
	        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
	        if "db_config" not in tables:
	            continue
	        cols = [r[1] for r in con.execute("PRAGMA table_info(db_config)") if "runtime" in r[1].lower()]
	        for col in cols:
	            qcol = '"' + col.replace('"', '""') + '"'
	            cur = con.execute(
	                f"UPDATE db_config SET {qcol} = 'crun' WHERE {qcol} IN ('runc', '/usr/bin/runc', '/usr/sbin/runc')"
	            )
	            changed += cur.rowcount
	        con.commit()
	    finally:
	        con.close()
	if changed:
	    print("updated")
	PY
	)
	if [[ $db_updated == updated ]]; then
		ok "updated Podman database default OCI runtime to crun"
	fi
	if ((sub_changed || conf_changed)) || [[ $db_updated == updated ]]; then
		SRV_PODMAN_USER="$pu" rt_podman system migrate --new-runtime crun >/dev/null 2>&1 || true
	fi
	SRV_PODMAN_USER="$pu" rt_podman info >/dev/null || die "podman info failed for $pu"
	bare_oci=$(SRV_PODMAN_USER="$pu" rt_as_podman_user podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null || true)
	if [[ -n $bare_oci && $bare_oci != crun ]]; then
		warn "default podman OCI runtime (without --runtime crun) is '$bare_oci'; restart running containers to complete migration to crun"
	fi

	say "quadlet networks and secrets"
	protect_data_secrets
	"$SRV" init-host
	load_lib secrets
	keys_podman_sync || warn "could not sync Podman secrets"
}
