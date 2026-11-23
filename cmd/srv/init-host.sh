# shellcheck shell=bash
# srv init-host subcommand (sourced by srv).

cmd_init_host() {
	need_root
	load_host
	mkdir -p "$SRV_STATE" "${HOST[volumes_dir]}"
	chmod 0755 "$SRV_STATE" "${HOST[volumes_dir]}"
	ensure_quadlet_networks
	if has_podman; then
		if pctl info >/dev/null 2>&1; then
			ok "podman user $(podman_user) ready"
		else
			warn "podman not ready for $(podman_user) (run: box podman)"
		fi
	fi
	ok "host ready"
}
