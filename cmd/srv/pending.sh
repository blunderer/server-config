# shellcheck shell=bash
# srv pending subcommand (sourced by srv).

# srv pending <svc|all>: what a deploy would change, without changing
# anything: the rendered configuration (repository + host values now vs the
# running release) and the images (pulled and built now vs the running
# containers' images).
cmd_pending() {
	local target=${1:?usage: srv pending <svc|all>} svc
	local -a svcs=("$target")
	load_host
	[[ $target == all ]] && mapfile -t svcs < <(enabled_services)
	for svc in "${svcs[@]}"; do
		pending_one "$svc" || return 1
	done
}

pending_one() {
	local svc=$1 cur dir rc=0 changed=() new old c f cname img img_nodig repo_only
	load_meta "$svc"
	info "${C_BLD}$svc${C_OFF}"
	cur=$(read_link "$svc" current)
	if [[ -z $cur ]]; then
		echo "  not deployed with srv yet: everything is pending (srv deploy $svc)"
		return 0
	fi
	dir=$(mktemp -d "$(svc_state "$svc")/.pending.XXXXXX")
	render_service "$svc" "$dir" pending || { rm -rf "$dir"; return 1; }

	echo "  configuration (release $cur -> repository and host values now):"
	if diff_release_trees "$(svc_state "$svc")/$cur" "$cur" "$dir" new -I '; Serial$' >"$dir.diff"; then
		echo "    no change"
	else
		grep -v '^diff -ru' "$dir.diff" | sed -e 's/\t.*$//' -e 's/^/    /'
		changed+=(configuration)
	fi
	rm -f "$dir.diff"

	echo "  images (running -> what a deploy would use; pulls and builds now):"
	{
		podman_pull_images "$dir" -q &&
			podman_build_images "$dir" pending -q
	} >"$dir.log" 2>&1 || { cat "$dir.log"; rc=1; }
	rm -f "$dir.log"
	if [[ $rc == 0 ]]; then
		for f in "$dir/quadlet"/*.container; do
			[[ -f $f ]] || continue
			cname=$(sed -n 's/^[[:space:]]*ContainerName=//p' "$f" | head -n 1)
			img=$(sed -n 's/^[[:space:]]*Image=//p' "$f" | head -n 1)
			new=$(pctl image inspect -f '{{.Id}}' "$img" 2>/dev/null || echo missing)
			new=${new#sha256:}
			old=$(pctl inspect -f '{{.Image}}' "$cname" 2>/dev/null || true)
			if [[ -z $old ]]; then
				img_nodig=${img%%@*}
				repo_only=$img_nodig
				[[ ${img_nodig##*/} == *:* ]] && repo_only=${img_nodig%:*}
				old=$(awk -v p="$repo_only" 'index($1, p ":") == 1 || index($1, p "@") == 1 || $1 == p { print $2; exit }' "$(svc_state "$svc")/$cur/release.info" 2>/dev/null || true)
			fi
			old=${old#sha256:}
			old=${old:-none}
			if [[ $old == "$new" ]]; then
				printf '    %-18s unchanged  %.19s\n' "$cname" "$new"
			else
				printf '    %-18s CHANGED    %.19s -> %.19s (%s)\n' "$cname" "$old" "$new" \
					"$(pctl image inspect -f '{{.Created}}' "$new" 2>/dev/null | cut -c1-10)"
				[[ " ${changed[*]} " == *" images "* ]] || changed+=(images)
			fi
		done
	fi

	# Files changed inside the containers (not in a volume or a mounted
	# path): a deploy creates new containers, so these are lost.
	local diffs n lost=0
	echo "  changed inside the containers (lost on deploy; volumes and mounts are kept):"
	for c in $(podman_containers_of_dir "$(svc_state "$svc")/$cur"); do
		diffs=$(container_changes "$c")
		[[ -n $diffs ]] || continue
		n=$(wc -l <<<"$diffs")
		lost=$((lost + n))
		echo "    $c:"
		head -n 15 <<<"$diffs" | sed 's/^/      /'
		((n <= 15)) || echo "      ... $((n - 15)) more (podman diff $c)"
	done
	[[ $lost -gt 0 ]] || echo "    nothing"
	rm -rf "$dir"
	if [[ ${#changed[@]} -gt 0 ]]; then
		echo "  pending: ${changed[*]} -> srv deploy $svc"
	elif [[ $rc == 0 ]]; then
		echo "  nothing pending"
	fi
	[[ $lost == 0 ]] || warn "$svc: $lost path(s) changed inside its containers would be lost by a deploy"
	return "$rc"
}

# container_changes CID: diff without runtime noise (/run, pid and
# socket files), mount points for volumes/bind mounts, and parent dirs.
container_changes() {
	local cid=$1 mounts
	mounts=$(pctl inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$cid" 2>/dev/null || true)
	pctl diff "$cid" 2>/dev/null || true |
		{ grep -vE '^[ACD] (/run|/var/run)(/|$)|\.(pid|sock)$' || [[ $? -eq 1 ]]; } |
		awk -v mounts="$mounts" '
			BEGIN { n = split(mounts, m, " ") }
			{
				# A mount point, or a directory created to hold one.
				for (i = 1; i <= n; i++)
					if ($2 == m[i] || index(m[i], $2 "/") == 1) next
				print
			}' |
		sort -k2 |
		awk '{ line[NR] = $0; path[NR] = $2 }
			END {
				for (i = 1; i <= NR; i++) {
					if (i < NR && index(path[i + 1], path[i] "/") == 1 && substr(line[i], 1, 1) == "C") continue
					print line[i]
				}
			}'
}
