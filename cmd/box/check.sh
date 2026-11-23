# shellcheck shell=bash disable=SC2015 # `test && ok || fail` reporting is intended
# box check subcommand (sourced by box).

cmd_check() {
	load_lib secrets
	load_lib tools
	load_lib checks
	local local_only=0
	while [[ ${1:-} == -* ]]; do
		case $1 in
			--local) local_only=1 ;;
			*) die "box check: unknown option $1" ;;
		esac
		shift
	done
	# Most checks read root-only state (keys, fail2ban, docker/podman, the journal):
	# as another user they would fail for the wrong reason.
	need_root
	need_env
	local data podman_storage volumes backup p svc owner pct

	say "host env"
	local svcs
	svcs=$(get services "")
	"$SRV" services >/dev/null 2>&1 && ok "$SRV_HOST_ENV: services ${svcs:-(none)}" ||
		fail "srv cannot read $SRV_HOST_ENV or a listed service does not exist"
	if [[ -z $svcs ]]; then
		ok "no services on this host"
	else
		# shellcheck disable=SC2086 # space-separated list
		"$SRV" check $svcs >/dev/null 2>&1 &&
			ok "every enabled service renders with this host's values" ||
			fail "rendering failed: run 'srv check' for details"
	fi

	say "folders"
	data=$(get data_dir /home/data)
	backup=$(get backup_dir /home/backup)
	volumes=$(get volumes_dir /home/volumes)
	podman_storage=$(get podman_storage_dir /home/podman)
	for p in "$data/" "$data/configs/" "$data/keys/" "$backup/" ${svcs:+"$volumes/"} ${svcs:+"$podman_storage/"}; do
		check_path "$p"
	done
	if [[ -d $data && -d $backup ]]; then
		if same_filesystem "$data" "$backup"; then
			ok "$backup and $data on the same filesystem (incremental backups use hard links)"
		else
			fail "$backup and $data are on different filesystems: hard links fail, every daily backup would be a full copy"
		fi
	fi
	check_data_folder

	say "files the services expect"
	while read -r svc p; do
		check_path "$p" "$svc"
	done < <("$SRV" requirements)

	say "ownership and permissions (uid 1000 = services, root:root 0700 = protected secrets & backups)"
	for p in "$data/keys/tor" "$data/www" "$data/mariadb-v2"; do
		[[ -e $p ]] || continue
		owner=$(stat -c %u "$p")
		[[ $owner == 1000 ]] && ok "$p owned by 1000" || warn "$p owned by uid $owner, services expect 1000"
	done
	local rel pmode
	for rel in "${PROTECTED_SECRET_DIRS[@]}"; do
		p="$data/$rel"
		[[ -d $p ]] || continue
		owner=$(stat -c %u:%g "$p")
		pmode=$(stat -c %a "$p")
		if [[ $owner == 0:0 ]] && (((8#$pmode & 8#077) == 0)); then
			ok "$p protected (root:root $pmode)"
		else
			fail "$p is not protected against $(unix_role) ($owner $pmode, expected root:root 0700): box podman"
		fi
	done
	if [[ -d $backup ]]; then
		owner=$(stat -c %u:%g "$backup")
		pmode=$(stat -c %a "$backup")
		if [[ $owner == 0:0 ]] && (((8#$pmode & 8#077) == 0)); then
			ok "$backup protected (root:root $pmode)"
		else
			fail "$backup is not protected against $(unix_role) ($owner $pmode, expected root:root 0700): box cron"
		fi
	fi
	while IFS= read -r -d '' p; do
		[[ $(stat -c %a "$p") =~ ^[0-7]00$ ]] && ok "$p not readable by others" ||
			warn "$p is readable by group/others (opendkim may refuse it): chmod 600"
	done < <(find "$data/keys/opendkim" -name '*.private' -print0 2>/dev/null)
	if [[ -e $data/keys/websso/oauth2.cfg ]]; then
		[[ $(stat -c %a "$data/keys/websso/oauth2.cfg") =~ ^[0-7]00$ ]] &&
			ok "$data/keys/websso/oauth2.cfg not readable by others" ||
			warn "$data/keys/websso/oauth2.cfg is readable by group/others: chmod 600"
		if [[ -z $(websso_val client_id "$data/keys/websso/oauth2.cfg") ||
			-z $(websso_val client_secret "$data/keys/websso/oauth2.cfg") ||
			-z $(websso_val cookie_secret "$data/keys/websso/oauth2.cfg") ]]; then
			fail "$data/keys/websso/oauth2.cfg is incomplete: box keys new websso"
		fi
	fi
	# Created as root (srv or box under sudo) before files went to the
	# data folder's owner (lib/data-owner.sh). lost+found and protected
	# root-only secret/backup dirs are intentionally owned by root.
	local downer roots n
	local -a prune_expr=(-path "$data/lost+found")
	for rel in "${PROTECTED_SECRET_DIRS[@]}"; do
		prune_expr+=(-o -path "$data/$rel")
	done
	downer=$(get data_owner "")
	if [[ -d $data && -n $downer && $downer != 0:* ]]; then
		roots=$(find "$data" -xdev \( "${prune_expr[@]}" \) -prune -o -user 0 -print 2>/dev/null || true)
		n=$(grep -c . <<<"$roots" || true)
		if [[ $n -eq 0 ]]; then
			ok "nothing outside protected secrets in $data belongs to root (data owner $downer)"
		else
			warn "$n path(s) in $data belong to root, not the data owner ($downer):"
			head -n 5 <<<"$roots" | sed 's/^/         /'
			((n <= 5)) || echo "         ... and $((n - 5)) more"
			echo "       To fix, chown the non-secret paths above to $downer."
		fi
	fi
	local onion
	onion=$(get onion_name "")
	if [[ -z $onion && " $(get services) " == *" onion "* ]]; then
		fail "onion is in services= but onion_name is not set: set it, or remove onion from services="
	fi
	if [[ -n $onion && ${#onion} -eq 16 ]]; then
		warn "onion_name is a v2 address (16 characters): Tor dropped v2 onion services in 2021"
	fi

	say "podman"
	local pu puid home udir gr port_start drift ovols oci
	pu=$(unix_role)
	if command -v podman >/dev/null 2>&1; then
		if id "$pu" >/dev/null 2>&1; then
			puid=$(id -u "$pu")
			home=$(getent passwd "$pu" | cut -d: -f6)
			udir="$home/.config/containers/systemd"
			if _subid_ok /etc/subuid "$pu" "$puid" && _subid_ok /etc/subgid "$pu" "$puid"; then
				ok "subuid/subgid configured for $pu"
			else
				fail "subuid/subgid missing or <65536 for $pu: box podman"
			fi
			if [[ $(loginctl show-user "$pu" -p Linger --value 2>/dev/null || true) == yes ]]; then
				ok "linger enabled for $pu"
			else
				fail "linger not enabled for $pu: box podman"
			fi
			if [[ -S /run/user/$puid/bus ]]; then
				ok "user D-Bus socket active (/run/user/$puid/bus)"
			else
				fail "user D-Bus socket missing (/run/user/$puid/bus): box podman"
			fi
			port_start=$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)
			if ((port_start <= 25)); then
				ok "unprivileged ports start at $port_start"
			else
				fail "net.ipv4.ip_unprivileged_port_start=$port_start (>25): box podman"
			fi
			if SRV_PODMAN_USER="$pu" rt_podman info >/dev/null 2>&1; then
				ok "podman rootless ready ($pu, $(podman --version | awk '{print $NF}'))"
				command -v crun >/dev/null 2>&1 || fail "crun is not installed: box packages"
				command -v catatonit >/dev/null 2>&1 || fail "catatonit is not installed: box packages"
				oci=$(SRV_PODMAN_USER="$pu" rt_as_podman_user podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null || true)
				if [[ -n $oci && $oci != crun ]]; then
					fail "podman OCI runtime is $oci, expected crun: box podman"
				elif [[ $oci == crun ]]; then
					ok "podman OCI runtime: crun"
				fi
				gr=$(SRV_PODMAN_USER="$pu" rt_podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
				if [[ -n $podman_storage ]]; then
					[[ $gr == "$podman_storage" ]] && ok "podman graphroot in $podman_storage" ||
						warn "podman graphroot is $gr, not $podman_storage: box podman"
				fi
			else
				fail "podman rootless failed for $pu: box podman"
			fi
			if [[ -n $svcs ]]; then
				local net
				for net in $("$SRV" networks); do
					[[ -f "$udir/$net.network" ]] && ok "quadlet network $net" || warn "missing $udir/$net.network: box podman"
				done
			fi
			drift=$(keys_podman_drift)
			if [[ -z $drift ]]; then
				ok "Podman secrets in sync with $data/keys"
			else
				warn "Podman secrets out of sync with $data/keys: box keys sync --restart"
			fi
		else
			fail "unix_role user '$pu' does not exist"
		fi
	else
		fail "podman not installed: box packages"
	fi
	ovols=$(old_volume_dirs)
	[[ -z $ovols ]] || warn "previous volume folder(s) still present ($ovols): srv deploy and srv commit move them to $volumes"

	if command -v podman >/dev/null 2>&1; then
		say "published ports"
		check_ports
	fi

	if (( ! local_only )) && [[ -n $(get "$(get host)_ip6" "") ]]; then
		say "ipv6"
		check_ipv6
	fi

	if [[ " $(get services) " == *" dns "* ]]; then
		say "dns port"
		local users53 l
		users53=$(port_53_users)
		[[ -z $users53 ]] && ok "port 53 is free for the dns service" || {
			fail "port 53 is taken by another program (box resolver):"
			while IFS= read -r l; do printf '         %s\n' "$l"; done <<<"$users53"
		}
		if resolved_installed && ! resolved_masked; then
			fail "systemd-resolved is not masked: it takes port 53 again at the next boot (box resolver)"
		fi
	fi

	if [[ " $(get services) " == *" mail "* ]]; then
		say "mail: reverse and forward names (receivers check both)"
		check_mail_names
		say "mail: delivery"
		check_mail_tables
		check_milter_log
		check_mail_queue
		check_smtp_auth
		check_blocklists
	fi

	if [[ " $(get services) " == *" mail "* || " $(get services) " == *" web "* ]]; then
		say "certificate and TLS"
		check_certificates
	fi

	if (( ! local_only )) && have_dig; then
		if [[ " $(get services) " == *" mail "* ]]; then
			say "mail: DKIM and SPF in DNS"
			check_dkim_dns
			check_spf
		fi
		if [[ $(get is_leader no) == yes ]]; then
			say "DNS (leader: checked once for every host)"
			check_dmarc
			check_nameservers
			check_delegation
		fi
		if [[ -n $(get smtp "") && " $(get services) " == *" dns "* ]]; then
			say "smtp.blunderer.org (this host's copy)"
			check_smtp_name
		fi
	fi

	say "shell"
	local su sh
	while read -r su sh; do check_shell_user "$su" "$sh"; done < <(shell_users)

	say "man pages"
	check_man

	say "ssh, fail2ban, cron, time"
	local port
	port=$(get ssh_port 222)
	ss -Htln "( sport = :$port )" | grep -q . && ok "sshd listens on $port" || fail "nothing listens on $port"
	if ss -Htln '( sport = :22 )' | grep -q .; then
		[[ $port == 22 ]] || warn "port 22 still open: box ssh-confirm once 'ssh -p $port' works"
	fi
	systemctl is-active -q fail2ban 2>/dev/null && ok "fail2ban: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')" ||
		fail "fail2ban is not running"
	check_own_ban
	[[ -f /etc/cron.d/srv ]] && ok "/etc/cron.d/srv installed" || fail "no /etc/cron.d/srv: box cron"
	local -a cron_users=(root "$(unix_role)")
	[[ $(admin_role) == "$(unix_role)" ]] || cron_users+=("$(admin_role)")
	for p in "${cron_users[@]}"; do
		crontab -l -u "$p" 2>/dev/null | grep -qvE '^\s*(#|$)' &&
			warn "user crontab of $p is not empty (old cron jobs? box cron replaces them)"
	done
	[[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && ok "clock synchronized" ||
		warn "clock not synchronized (TLS, DKIM and ACME need the right time)"

	say "unix role and ssh between hosts"
	check_unix_role
	check_ssh_peers
	check_ssh_clients

	say "services (current releases)"
	local status
	status=$("$SRV" status 2>/dev/null | tail -n +2)
	if [[ -z $status ]]; then
		warn "srv status shows nothing"
	elif grep -qE 'unhealthy|exited|dead|restarting|created|stopped' <<<"$status"; then
		fail "unhealthy or stopped containers:"
		grep -E 'unhealthy|exited|dead|restarting|created|stopped' <<<"$status" | sed 's/^/         /'
	else
		ok "all current containers running and healthy"
	fi
	local pending
	pending=$(awk '$3 != "-" {print $1}' <<<"$status" | xargs)
	[[ -n $pending ]] && warn "not committed yet (rollback targets kept): $pending"
	if alerts_configured; then
		[[ -s /etc/msmtprc ]] && ok "email alerts to $(get alert_email)" || warn "alerts not installed: box alerts"
	else
		warn "no alert_email: failures are not emailed"
	fi

	if backups_paused; then
		local age=$(( ($(date +%s) - $(stat -c %Y "$PAUSE_FLAG")) / 3600 ))
		((age >= 24)) && warn "backups paused for ${age}h (box backups resume)" ||
			ok "backups paused since $(paused_since) (box backups resume)"
	fi

	say "disk and system"
	local -a df_paths=(/ "$data" ${svcs:+"$volumes"} ${svcs:+"$podman_storage"})
	for p in "${df_paths[@]}"; do
		[[ -e $p ]] || continue
		pct=$(df -P "$p" | awk 'NR==2 {gsub("%", "", $5); print $5}')
		((pct < 85)) && ok "$p: ${pct}% used" || warn "$p: ${pct}% used"
	done
	ok "journal: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]?B?' | head -1) (cap 2G)"
	[[ -f /var/run/reboot-required ]] && warn "reboot required ($(xargs </var/run/reboot-required.pkgs 2>/dev/null))"

	echo
	if ((FAILURES > 0)); then
		echo "${C_RED}$FAILURES failure(s)${C_OFF}, $WARNINGS warning(s)"
		return 1
	fi
	echo "${C_GRN}ready${C_OFF}, $WARNINGS warning(s)"
}
