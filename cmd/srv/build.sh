# shellcheck shell=bash
# srv build subcommand (sourced by srv).

# srv build <svc|all>: pull the images and build the local ones, without
# creating or starting anything. A later `srv deploy` then finds everything
# in the image store and build cache, so the switch itself is quick (e.g.
# fetch before a maintenance window, or check that a Dockerfile builds).
cmd_build() {
	need_root
	local parallel=0 jobs=${SRV_BUILD_JOBS:-4}
	while [[ ${1:-} == -* ]]; do
		case $1 in
			-v | --verbose)
				# shellcheck disable=SC2034 # read by _podman_pretty in srv
				SRV_VERBOSE=1
				;;
			-p | --parallel) parallel=1 ;;
			-j)
				shift
				jobs=${1:?srv build: -j requires a number}
				[[ $jobs =~ ^[1-9][0-9]*$ ]] || die "srv build: invalid -j value '$jobs'"
				parallel=1
				;;
			*) die "srv build: unknown option $1" ;;
		esac
		shift
	done
	local target=${1:?usage: srv build [-p] [-j N] [-v] <svc|all>} svc
	local -a svcs=("$target")
	load_host
	[[ $target == all ]] && mapfile -t svcs < <(enabled_services)
	if ((parallel && ${#svcs[@]} > 1)); then
		build_parallel "$jobs" "${svcs[@]}"
		return
	fi
	# Parallelize containers inside a service only when building a single service
	# (not during serial `srv build all`).
	local svc_jobs=${jobs}
	((${#svcs[@]} > 1)) && svc_jobs=1
	for svc in "${svcs[@]}"; do
		build_one "$svc" "$svc_jobs" || { warn "$svc: build failed"; return 1; }
	done
}

build_parallel() {
	local max_jobs=$1
	shift
	local -a svcs=("$@") all_jobs=() tmpdirs=()
	local -A seen_pulls=()
	local svc dir line kind arg1 rc=0
	info "preparing ${#svcs[@]} services for parallel build (up to $max_jobs jobs)"
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		ensure_infra "$svc"
		dir=$(mktemp -d "$(svc_state "$svc")/.build.XXXXXX")
		tmpdirs+=("$dir")
		render_service "$svc" "$dir" build || { rc=1; break; }
		validate_quadlets "$dir" || { rc=1; break; }
		while IFS= read -r line; do
			[[ -n $line ]] || continue
			IFS=$'\t' read -r kind _ arg1 _ <<<"$line"
			if [[ $kind == pull ]]; then
				[[ -z ${seen_pulls[$arg1]+set} ]] || continue
				seen_pulls[$arg1]=1
			fi
			all_jobs+=("$line")
		done < <(podman_collect_service_jobs "$dir" build "$svc: ")
	done
	if ((rc == 0 && ${#all_jobs[@]} > 0)); then
		_podman_run_jobs "$max_jobs" "${all_jobs[@]}" || rc=$?
	fi
	for dir in "${tmpdirs[@]}"; do rm -rf "$dir"; done
	if ((rc == 0)); then
		ok "all images ready (${svcs[*]})"
	else
		warn "parallel build failed"
	fi
	return "$rc"
}

build_one() {
	local svc=$1 max_jobs=${2:-${SRV_BUILD_JOBS:-4}} dir
	load_meta "$svc"
	info "${C_BLD}$svc${C_OFF}: pulling and building (nothing is started)"
	ensure_infra "$svc"
	dir=$(mktemp -d "$(svc_state "$svc")/.build.XXXXXX")
	local rc=0
	build_in "$svc" "$dir" "$max_jobs" || rc=$?
	rm -rf "$dir"
	[[ $rc == 0 ]] && ok "$svc: images ready; srv deploy $svc will use them"
	return "$rc"
}

build_in() {
	local svc=$1 dir=$2 max_jobs=${3:-${SRV_BUILD_JOBS:-4}} image
	render_service "$svc" "$dir" build || return 1
	validate_quadlets "$dir" || return 1
	podman_sync_images "$dir" build "" "$max_jobs" || return 1
	sed -n 's/^[[:space:]]*Image=//p' "$dir/quadlet"/*.container | sort -u | while read -r image; do
		pctl image inspect -f "  $image  {{.Id}}  {{.Created}}" "$image" 2>/dev/null ||
			echo "  $image  (not available)"
	done
}
