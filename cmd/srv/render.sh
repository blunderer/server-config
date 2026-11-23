# shellcheck shell=bash
# srv render subcommand (sourced by srv).

cmd_render() {
	local svc=${1:?usage: srv render <svc> [dir]} dir=${2:-}
	load_host
	load_meta "$svc"
	[[ -n $dir ]] || dir=$(mktemp -d "/tmp/srv-render-$svc.XXXXXX")
	render_service "$svc" "$dir" render
	echo "$dir"
}
