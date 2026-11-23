# shellcheck shell=bash
# box migrate subcommand (sourced by box).

# box migrate SRC DEST: point the website records from SRC to DEST.
# Run on the DNS master. Data is not moved: DEST must already run the
# services, with data as recent as needed, and backups must be paused
# everywhere so no copy overwrites the other host meanwhile.
cmd_migrate() {
	need_root
	need_env
	local src=${1:?usage: box migrate <src> <dest>} dest=${2:?usage: box migrate <src> <dest>}
	local src_ip dest_ip code name
	src_ip=$(host_ip "$src")
	dest_ip=$(host_ip "$dest")

	say "migrate websites: $src ($src_ip) -> $dest ($dest_ip)"
	need_leader
	[[ $(get web) == "$src" ]] || die "the websites are on $(get web), not $src"
	[[ $src != "$dest" ]] || die "source and destination are the same"

	echo
	echo "1. Does $dest run every website service, with its data in place?"
	echo "   Refresh the database on $dest first (standbys do not auto-import dumps):"
	echo "     On $src: srv hook db dump --force   (and box data push $dest on the leader)"
	echo "     On $dest: srv hook db import-newest"
	echo "   On $dest: srv status   (web, db, onion: running and healthy)"
	echo "             box check"
	echo "   Probe from here (HTTPS on $dest_ip, Host: $(get_site_name)):"
	for name in $(get_site_name) "dl.$(get_site_name)"; do
		code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
			--resolve "$name:443:$dest_ip" "https://$name/" 2>/dev/null || true)
		[[ -z $code || $code == 000 ]] && code="no answer"
		echo "     https://$name/ -> HTTP $code"
	done
	confirm "   Confirm that $dest runs all the services?" || die "stopped: nothing changed"

	echo
	echo "2. Are backups, replication and certificate renewal paused on EVERY host?"
	echo "   On each host: box backups pause     (check: box backups status)"
	echo "   Here: $(run_cmd backups status)"
	backups_paused || echo "   ${C_YLW}not paused on this host${C_OFF}"
	confirm "   Confirm that they are paused everywhere?" || die "stopped: nothing changed"

	echo
	echo "3. Pointing the website records to $dest ($dest_ip) and deploying dns."
	set_inventory web "$dest"
	SRV_YES=1 "$SRV" deploy dns || {
		set_inventory web "$src"
		die "dns deploy failed: web=$src restored (srv status dns, srv logs dns)"
	}
	SRV_YES=1 "$SRV" commit dns >/dev/null || true
	wait_for_slaves "$dest_ip"

	echo
	ok "websites now point to $dest ($dest_ip); resolvers follow within the zone TTL (5 min)"
	echo "   Back: box migrate $dest $src"
	echo "   web=$dest is set in this host's inventory; the others get it with the next"
	echo "   replication (box backups resume, on each host, when you are done)."
}
