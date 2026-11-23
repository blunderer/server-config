# shellcheck shell=bash
# box smtp-health subcommand (sourced by box).

cmd_smtp_health() {
	need_root
	need_env
	[[ " $(get services) " == *" dns "* ]] || die "no dns service on this host: nothing to update"
	local all=() healthy=() wanted served h t a down
	read -ra all <<<"$(get smtp "")"
	((${#all[@]})) || die "no smtp= in the inventory: nothing to keep in $SMTP_ZONE"
	command -v nsupdate >/dev/null || die "nsupdate is missing: box packages (bind9-dnsutils)"
	[[ -r $(smtp_key) ]] || die "no $(smtp_key): srv deploy dns creates it"
	[[ -n $(alerts_account) && -s $(alerts_pw_file) ]] ||
		warn "no alerts account here: only checking that port 587 greets (box alerts-account)"
	mapfile -t healthy < <(smtp_healthy_hosts)
	down=()
	for h in "${all[@]}"; do
		[[ " ${healthy[*]} " == *" $h "* ]] || down+=("$h")
	done
	smtp_alerter "${healthy[@]}" && smtp_health_alert "${down[*]}" "${healthy[*]}"
	if ((${#healthy[@]} == 0)); then
		warn "no mail host works: keeping all of them in $SMTP_ZONE"
		healthy=("${all[@]}")
	fi
	wanted=$(smtp_records_for "${healthy[@]}")
	served=$(smtp_served)
	if [[ $wanted == "$served" ]]; then
		ok "$SMTP_ZONE: ${healthy[*]}"
		return 0
	fi
	{
		echo "server 127.0.0.1"
		echo "zone $SMTP_ZONE"
		echo "update delete $SMTP_ZONE. A"
		echo "update delete $SMTP_ZONE. AAAA"
		while read -r t a; do
			[[ -n $t ]] && echo "update add $SMTP_ZONE. 60 $t $a"
		done <<<"$wanted"
		echo "send"
	} | nsupdate -k "$(smtp_key)" || die "nsupdate failed: $SMTP_ZONE unchanged"
	ok "$SMTP_ZONE now: ${healthy[*]}"
}
