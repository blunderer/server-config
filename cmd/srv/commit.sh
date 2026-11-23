# shellcheck shell=bash
# srv commit subcommand (sourced by srv).

cmd_commit() {
	need_root
	local target=${1:?usage: srv commit <svc|all>}
	load_host
	if [[ $target == all ]]; then
		local s
		for s in $(enabled_services); do commit_one "$s"; done
		return 0
	fi
	commit_one "$target"
}

# volume_dir_in_use DIR VOL MOUNTS: 0 if DIR (realpath) is bind-mounted by any
# remaining container (MOUNTS) or referenced by any service's current/previous.
volume_dir_in_use() {
	local dir=$1 vol=$2 mounts=$3 m mr sdir link rel rb f
	while IFS= read -r m; do
		[[ -n $m ]] || continue
		mr=$(realpath -m "$m")
		if [[ $mr == "$dir" || $mr == "$dir"/* || $dir == "$mr"/* ]]; then
			return 0
		fi
	done <<<"$mounts"
	for sdir in "$SRV_STATE"/*/; do
		for link in current previous; do
			[[ -L "$sdir$link" ]] || continue
			rel=$(basename "$(readlink "$sdir$link")")
			if [[ -d "$sdir$rel/quadlet" ]]; then
				rb=''
				[[ -f "$sdir$rel/.env" ]] && rb=$(sed -n 's/^SRV_VOLUMES=//p' "$sdir$rel/.env" | tail -n 1)
				for f in "$sdir$rel/quadlet"/*.container; do
					[[ -f $f ]] || continue
					grep -qE "^[[:space:]]*Volume=$dir([:/[:space:],]|\$)" "$f" && return 0
					if [[ -n $rb && $(realpath -m "$rb/$vol") == "$dir" ]]; then
						grep -qE "^[[:space:]]*Volume=$rb/$vol([:/[:space:],]|\$)" "$f" && return 0
					fi
				done
			fi
		done
	done
	return 1
}

commit_one() {
	local svc=$1 cur prev
	load_meta "$svc"
	cur=$(read_link "$svc" current)
	prev=$(read_link "$svc" previous)
	[[ -n $cur ]] || { warn "$svc: nothing deployed"; return 0; }
	if [[ -n $prev ]]; then
		confirm "$svc: delete containers of previous release $prev?" || return 0
		drop_release "$svc" "$prev"
		set_link "$svc" previous ''
	fi
	local v cur_base host_real cur_real b b_real mounts='' pmounts='' d
	local -a old_bases=() cleanup_parents=() old_dirs=() cand_vols=() removed=()
	cur_base=$(release_volumes_dir "$svc" "$cur")
	host_real=$(realpath -m "${HOST[volumes_dir]}")
	cur_real=$(realpath -m "${cur_base:-${HOST[volumes_dir]}}")
	while IFS= read -r b; do
		[[ -n $b ]] || continue
		b_real=$(realpath -m "$b")
		[[ $b_real != "$host_real" && $b_real != "$cur_real" ]] || continue
		[[ $b_real != "$host_real"/* && $host_real != "$b_real"/* ]] || continue
		[[ $b_real != "$cur_real"/* && $cur_real != "$b_real"/* ]] || continue
		[[ " ${old_bases[*]} " == *" $b_real "* ]] || { old_bases+=("$b_real"); cleanup_parents+=("$b_real"); }
	done < <(sed -n 's/^SRV_VOLUMES=//p' "$(svc_state "$svc")"/*/.env 2>/dev/null | sort -u)
	mapfile -t cand_vols < <(for v in $(service_volumes "$svc"); do echo "$v"; done | awk 'NF && !seen[$0]++')
	if ((${#old_bases[@]} > 0)); then
		if has_podman; then
			local -a pctrs=()
			mapfile -t pctrs < <(pctl ps -aq 2>/dev/null || true)
			if ((${#pctrs[@]} > 0)); then
				pmounts=$(pctl inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "${pctrs[@]}" 2>/dev/null || true)
				[[ -n $pmounts ]] && mounts="$pmounts"
			fi
		fi
		for b in "${old_bases[@]}"; do
			for v in "${cand_vols[@]}"; do
				d="$b/$v"
				[[ $d == /* && $d != / && ! -L $d && -d $d ]] || continue
				if ! volume_dir_in_use "$d" "$v" "$mounts" &&
					[[ " ${old_dirs[*]} " != *" $d "* ]]; then
					old_dirs+=("$d")
				fi
			done
		done
		if ((${#old_dirs[@]} > 0)) &&
			confirm "$svc: delete migrated volume folder(s) (${old_dirs[*]})? Their data is kept in ${cur_base:-${HOST[volumes_dir]}}."; then
			for d in "${old_dirs[@]}"; do
				if unmount_tree "$d"; then
					rm -rf -- "$d"
					removed+=("$d")
				fi
			done
			for b in "${cleanup_parents[@]}"; do rmdir "$b" 2>/dev/null || true; done
			((${#removed[@]} == 0)) || ok "removed old volume folder(s): ${removed[*]}"
		fi
	fi
	prune_releases "$svc" "$cur"
	prune_podman
	ok "$svc committed on $cur"
}

# prune_podman: remove unused Podman images not referenced by any current or
# previous Quadlet release or existing container.
prune_podman() {
	has_podman || return 0
	local -A keep_imgs=() keep_ids=()
	local sdir link rel f img id repo tag lego_img=''
	for sdir in "$SRV_STATE"/*/; do
		[[ -d $sdir ]] || continue
		for link in current previous; do
			[[ -L "$sdir$link" ]] || continue
			rel=$(basename "$(readlink "$sdir$link")")
			for f in "$sdir$rel/quadlet"/*.container; do
				[[ -f $f ]] || continue
				img=$(sed -n 's/^[[:space:]]*Image=//p' "$f" | head -n 1)
				[[ -n $img ]] || continue
				[[ $img == *:* || $img == *@* ]] || img+=":latest"
				keep_imgs["$img"]=1
			done
		done
	done
	if [[ -r $SRV_ROOT/ssl/acme.conf ]]; then
		lego_img=$(sed -nE 's/^[[:space:]]*LEGO_IMAGE="?([^"#]*)"?.*$/\1/p' "$SRV_ROOT/ssl/acme.conf" | tail -n 1)
		lego_img=${lego_img%"${lego_img##*[![:space:]]}"}
		[[ -z $lego_img ]] || keep_imgs["$lego_img"]=1
	fi
	for img in "${!keep_imgs[@]}"; do
		id=$(pctl image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)
		id=${id#sha256:}
		[[ -n $id ]] && keep_ids["$id"]=1
	done
	while read -r id; do
		id=${id#sha256:}
		[[ -n $id ]] && keep_ids["$id"]=1
	done < <(pctl ps -aq --no-trunc --format '{{.ImageID}}' 2>/dev/null || true)
	pctl image prune -f --filter until=168h >/dev/null 2>&1 || true
	while read -r id repo tag; do
		id=${id#sha256:}
		[[ -n $repo && $repo != '<none>' ]] || continue
		if [[ $tag == '<none>' ]]; then
			[[ -n ${keep_ids[$id]+set} ]] || pctl rmi "$id" >/dev/null 2>&1 || true
			continue
		fi
		img="${repo}:${tag}"
		[[ -n ${keep_imgs[$img]+set} ]] && continue
		if [[ $repo == localhost/srv/* || -z ${keep_ids[$id]+set} ]]; then
			pctl rmi "$img" >/dev/null 2>&1 || true
		fi
	done < <(pctl images --no-trunc --format '{{.ID}} {{.Repository}} {{.Tag}}' 2>/dev/null || true)
}

# prune_releases SVC CURRENT: keep the newest $SRV_KEEP directories that are
# neither current nor previous.
prune_releases() {
	local svc=$1 cur=$2 prev d rel n=0
	prev=$(read_link "$svc" previous)
	local -a dirs
	mapfile -t dirs < <(find "$(svc_state "$svc")" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
	for rel in "${dirs[@]}"; do
		[[ $rel == "$cur" || $rel == "$prev" ]] && continue
		n=$((n + 1))
		if ((n > SRV_KEEP)); then
			d="$(svc_state "$svc")/$rel"
			rm -rf "$d"
		fi
	done
}
