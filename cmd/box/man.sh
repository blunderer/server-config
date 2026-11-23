# shellcheck shell=bash
# box man subcommand (sourced by box).

cmd_man() {
	need_root
	need_env
	say "man: the containers' manual pages on the host"
	export DEBIAN_FRONTEND=noninteractive
	command -v man >/dev/null || apt-get install -y -q man-db
	local tmp pkg deb f n=0 missing=()
	local -a pkgs
	mapfile -t pkgs < <(man_wanted)
	if ((${#pkgs[@]} == 0)); then
		ok "no service of this host lists MANPAGES"
		return 0
	fi
	tmp=$(mktemp -d)
	# shellcheck disable=SC2064 # expand now: tmp is local
	trap "rm -rf '$tmp'" RETURN
	mkdir -p "$tmp/deb" "$tmp/root"
	for pkg in "${pkgs[@]}"; do
		if (cd "$tmp/deb" && apt-get download -q -o APT::Sandbox::User=root "$pkg" >/dev/null 2>&1); then
			deb=$(find "$tmp/deb" -name "${pkg}_*.deb" | head -n 1)
			dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$tmp/root" --wildcards './usr/share/man/*' 2>/dev/null || true
		else
			missing+=("$pkg")
		fi
	done
	((${#missing[@]} == 0)) || warn "not in the apt sources, skipped: ${missing[*]}"

	# Remove what the previous run installed, then install this run's pages,
	# except those the host already has from its own packages.
	if [[ -f $MAN_STATE.files ]]; then
		while read -r f; do rm -f "$MAN_DIR/$f"; done <"$MAN_STATE.files"
	fi
	: >"$MAN_STATE.files.new"
	if [[ -d $tmp/root/usr/share/man ]]; then
		while IFS= read -r -d '' f; do
			f=${f#"$tmp/root/usr/share/man/"}
			[[ -e /usr/share/man/$f ]] && continue
			install -D -m 0644 "$tmp/root/usr/share/man/$f" "$MAN_DIR/$f"
			echo "$f" >>"$MAN_STATE.files.new"
			n=$((n + 1))
		done < <(find "$tmp/root/usr/share/man" -type f -print0)
	fi
	mv "$MAN_STATE.files.new" "$MAN_STATE.files"
	printf '%s\n' "${pkgs[@]}" >"$MAN_STATE"
	mandb -q 2>/dev/null || true
	ok "$n page(s) from ${pkgs[*]} (man postconf, man 5 named.conf...)"
}
