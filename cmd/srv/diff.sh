# shellcheck shell=bash
# srv diff subcommand (sourced by srv).

cmd_diff() {
	local svc=${1:?usage: srv diff <svc>} cur prev
	load_host
	cur=$(read_link "$svc" current)
	prev=$(read_link "$svc" previous)
	[[ -n $cur && -n $prev ]] || die "$svc needs a current and a previous srv release to diff"
	diff_release_trees "$(svc_state "$svc")/$prev" "$prev" "$(svc_state "$svc")/$cur" "$cur" || true
}
