# shellcheck shell=bash
# srv discard subcommand (sourced by srv).

# srv discard <svc|all> [RELEASE...]: remove releases that are not in use
# (orphan_releases), or the named ones; never the current or previous one.
cmd_discard() {
	need_root
	local target=${1:?usage: srv discard <svc|all> [RELEASE...]} svc rel cur prev
	shift
	load_host
	local -a svcs=("$target")
	[[ $target == all ]] && mapfile -t svcs < <(all_services)
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		cur=$(read_link "$svc" current)
		prev=$(read_link "$svc" previous)
		local -a rels=("$@")
		((${#rels[@]})) || mapfile -t rels < <(orphan_releases "$svc")
		if ((${#rels[@]} == 0)); then
			[[ $target == all ]] || ok "$svc: no release to discard"
			continue
		fi
		for rel in "${rels[@]}"; do
			[[ $rel != "$cur" ]] || die "$svc: $rel is the current release (srv rollback first)"
			[[ $rel != "$prev" ]] || die "$svc: $rel is the previous release, the rollback target (srv commit $svc removes it)"
		done
		confirm "$svc: remove release(s) ${rels[*]} (containers, images built for them, folders)?" || continue
		for rel in "${rels[@]}"; do discard_release "$svc" "$rel"; done
	done
	load_cmd commit
	prune_podman
}
