# shellcheck shell=bash
# box leader subcommand (sourced by box).

# box leader --force NAME: the leader is dead or unreachable; NAME (this
# host) takes over from its own copy of the data. Run on NAME.
cmd_leader_force() {
	local new=${1:?usage: box leader --force <this host>} old self h user data move_web=no
	old=$(get leader)
	self=$(get host)
	host_ip "$new" >/dev/null
	[[ $new == "$self" ]] || die "run this on $new itself (this host is $self)"
	[[ $new != "$old" ]] || die "$new is already the leader"
	user=$(admin_role)
	data=$(get data_dir /home/data)

	say "take over the leader role: $old (unreachable) -> $new (this host)"
	cat <<-EOF
	  Use this only when $old is down or unreachable. Otherwise, run
	  box leader $new on $old: it hands over cleanly.

	  This host continues from its own copy of the data folder, as of the last
	  replication from $old (newest database dump: $(newest_dump)).
	  When $old comes back, it will not push its stale data or certificates:
	  every host's inventory names $new as the leader, and pushes are refused.
	EOF
	confirm "  $old is really down, and $new takes over?" || die "stopped: nothing changed"
	if [[ $(get web) == "$old" ]]; then
		confirm "  The websites are on $old: move them to $new too (web=$new)?" && move_web=yes
	fi

	local inventory
	inventory=$(get hosts_file)
	if [[ $move_web == yes ]]; then
		set_inventory_in "$inventory" leader "$new" web "$new"
	else
		set_inventory_in "$inventory" leader "$new"
	fi
	ok "inventory: leader=$new$([[ $move_web == yes ]] && echo ", web=$new")"
	for h in $(get hosts); do
		[[ $h == "$self" || $h == "$old" ]] && continue
		if rsync -rlptgo --no-g -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$inventory" "$user@$(get "${h}_ip"):$data/configs/hosts.env"; then
			ok "inventory copied to $h"
		else
			warn "could not copy the inventory to $h: copy $inventory there by hand"
		fi
	done

	cat <<-EOF

	  Now, on $new (here):
	    srv deploy dns                  becomes the DNS master
	EOF
	if [[ $move_web == yes ]]; then
		cat <<-EOF
		    add web, db, onion to services= in $(readlink -f "$SRV_HOST_ENV"), then:
		    srv deploy db                   an empty database imports the newest dump
		    srv deploy web; srv deploy onion
		EOF
	fi
	cat <<-EOF
	    box cron                   replication and certificate renewal jobs
	    box audit
	  On every other host: srv deploy dns (slave of $new), box cron.
	  When $old is back: see docs/runbooks.md, "A host died".
	EOF
}

# box leader NAME: hand the leader role (DNS master, replication source,
# certificate renewal) to another host. Run on the current leader.
cmd_leader() {
	need_root
	need_env
	if [[ ${1:-} == --force ]]; then
		shift
		cmd_leader_force "$@"
		return
	fi
	local new=${1:?usage: box leader [--force] <host>} old h user data
	old=$(get leader)
	host_ip "$new" >/dev/null
	[[ $new != "$old" ]] || die "$new is already the leader"
	need_leader
	user=$(admin_role)
	data=$(get data_dir /home/data)

	say "hand the leader role: $old -> $new"
	echo "  The leader is the DNS master, pushes the data folder to the other hosts"
	echo "  and renews the certificates. Before handing it over:"
	echo "  - $new has the current data (run the replication now if needed:"
	echo "    box data push $new);"
	echo "  - backups are paused on every host (box backups pause)."
	confirm "  Both done?" || die "stopped: nothing changed"

	set_inventory leader "$new"
	# Replication is paused and now flows from the new leader: copy the
	# inventory to every host so they all agree on the leader.
	for h in $(get hosts); do
		[[ $h == "$(get host)" ]] && continue
		if rsync -rlptgo --no-g -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$(get hosts_file)" "$user@$(get "${h}_ip"):$data/configs/hosts.env"; then
			ok "inventory copied to $h"
		else
			warn "could not copy the inventory to $h: copy $(get hosts_file) there by hand"
		fi
	done

	cat <<-EOF

	  Inventory updated (leader=$new). Now, in this order:
	    on $new:  srv deploy dns          (becomes the DNS master)
	              box cron           (replication and certificate renewal jobs)
	    on $old (here) and every other host:
	              srv deploy dns          (becomes a slave of $new)
	              box cron
	    then on every host: box audit (should show no drift), box backups resume
	EOF
}
