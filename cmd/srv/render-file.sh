# shellcheck shell=bash
# srv render-file subcommand (sourced by srv).

cmd_render_file() {
	local src=${1:?usage: srv render-file <in> <out>} dst=${2:?usage: srv render-file <in> <out>}
	load_host
	cp "$src" "$dst"
	render_file "$dst"
}
