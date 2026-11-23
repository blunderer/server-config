# shellcheck shell=bash
# Dynamic bash tab-completion for srv, box, remote (and sudo srv/box/remote).
# Sourced by host/shell/bashrc; discovers subcommands from cmd/{srv,box}/*.sh,
# services from host config / services/*, hooks, and container names from quadlet/*.container.

__srv_repo_root() {
	local bin
	bin=$(command -v srv 2>/dev/null || command -v box 2>/dev/null) || return 1
	dirname "$(readlink -f "$bin")"
}

__srv_list_cmds() {
	local root=$1 dir=$2 f
	for f in "$root/cmd/$dir"/*.sh; do
		[[ -f $f ]] || continue
		f=${f##*/}
		printf '%s\n' "${f%.sh}"
	done
}

__srv_list_services() {
	local root=$1 svcs='' d
	if command -v srv >/dev/null 2>&1; then
		svcs=$(srv get services '' 2>/dev/null || true)
	fi
	if [[ -n $svcs ]]; then
		printf '%s\n' "$svcs" | tr ' ' '\n'
		return 0
	fi
	for d in "$root/services"/*/; do
		[[ -d $d ]] || continue
		d=${d%/}
		printf '%s\n' "${d##*/}"
	done
}

__srv_list_containers() {
	local root=$1 svc=$2 f c insts
	if [[ $svc == agy ]]; then
		insts=''
		if command -v srv >/dev/null 2>&1; then
			insts=$(srv get agy_instances '' 2>/dev/null || true)
		fi
		if [[ -n $insts ]]; then
			printf '%s\n' "$insts" | tr ' ' '\n'
		else
			printf '%s\n' agy
		fi
		return 0
	fi
	for f in "$root/services/$svc/quadlet"/*.container; do
		[[ -f $f ]] || continue
		c=$(sed -n 's/^[[:space:]]*ContainerName=//p' "$f" | head -n 1)
		[[ -n $c ]] || continue
		c=${c#"srv-${svc}-"}
		printf '%s\n' "$c"
	done
}

_srv_complete_from() {
	local start=$1 cur root cmds svcs cmd i
	cur=${COMP_WORDS[COMP_CWORD]}
	root=$(__srv_repo_root) || return 0
	i=$start
	while ((i < COMP_CWORD)) && [[ ${COMP_WORDS[i]} == -* ]]; do
		i=$((i + 1))
	done
	if ((COMP_CWORD == i)); then
		cmds=$(__srv_list_cmds "$root" srv)
		mapfile -t COMPREPLY < <(compgen -W "-y -v --verbose $cmds" -- "$cur")
		return 0
	fi
	cmd=${COMP_WORDS[i]}
	local arg_idx=$((i + 1))
	while ((arg_idx < COMP_CWORD)) && [[ ${COMP_WORDS[arg_idx]} == -* ]]; do
		arg_idx=$((arg_idx + 1))
	done
	case $cmd in
		build | deploy | commit | discard | pending)
			if ((COMP_CWORD == arg_idx)); then
				svcs=$(__srv_list_services "$root")
				local opts=''
				[[ $cmd == build ]] && opts='-p --parallel -j -v --verbose'
				[[ $cmd == deploy ]] && opts='-v --verbose --commit'
				mapfile -t COMPREPLY < <(compgen -W "$opts all $svcs" -- "$cur")
			fi
			;;
		status | stats | stop | start | restart | reload | diff | rollback | render | check)
			svcs=$(__srv_list_services "$root")
			mapfile -t COMPREPLY < <(compgen -W "$svcs" -- "$cur")
			;;
		logs | shell | exec)
			if ((COMP_CWORD == arg_idx)); then
				svcs=$(__srv_list_services "$root")
				mapfile -t COMPREPLY < <(compgen -W "$svcs" -- "$cur")
			elif ((COMP_CWORD == arg_idx + 1)); then
				local svc=${COMP_WORDS[arg_idx]} ctrs
				ctrs=$(__srv_list_containers "$root" "$svc")
				local extra=''
				[[ $cmd == exec ]] && extra='--'
				mapfile -t COMPREPLY < <(compgen -W "$extra $ctrs" -- "$cur")
			fi
			;;
		hook)
			if ((COMP_CWORD == arg_idx)); then
				svcs=$(__srv_list_services "$root")
				mapfile -t COMPREPLY < <(compgen -W "list $svcs" -- "$cur")
			elif ((COMP_CWORD == arg_idx + 1)) && [[ ${COMP_WORDS[arg_idx]} != list ]]; then
				local svc=${COMP_WORDS[arg_idx]} h hooks=''
				for h in "$root/services/$svc/hooks"/*; do
					[[ -x $h && -f $h ]] && hooks+=" ${h##*/}"
				done
				mapfile -t COMPREPLY < <(compgen -W "$hooks" -- "$cur")
			fi
			;;
	esac
}

_box_complete_from() {
	local start=$1 cur root cmds i
	cur=${COMP_WORDS[COMP_CWORD]}
	root=$(__srv_repo_root) || return 0
	i=$start
	while ((i < COMP_CWORD)) && [[ ${COMP_WORDS[i]} == -* ]]; do
		i=$((i + 1))
	done
	if ((COMP_CWORD == i)); then
		cmds=$(__srv_list_cmds "$root" box)
		mapfile -t COMPREPLY < <(compgen -W "-q --quiet $cmds" -- "$cur")
		return 0
	fi
	case ${COMP_WORDS[i]} in
		check) mapfile -t COMPREPLY < <(compgen -W "--local -q" -- "$cur") ;;
		apply-role-change) mapfile -t COMPREPLY < <(compgen -W "-n --dry-run" -- "$cur") ;;
		login) mapfile -t COMPREPLY < <(compgen -W "-s" -- "$cur") ;;
		backups) mapfile -t COMPREPLY < <(compgen -W "pause resume status" -- "$cur") ;;
		data) mapfile -t COMPREPLY < <(compgen -W "push pull" -- "$cur") ;;
		keys) mapfile -t COMPREPLY < <(compgen -W "list sync new rotate delete show help" -- "$cur") ;;
		mail) mapfile -t COMPREPLY < <(compgen -W "trace test config user" -- "$cur") ;;
		ban) mapfile -t COMPREPLY < <(compgen -W "list unban why" -- "$cur") ;;
		minecraft) mapfile -t COMPREPLY < <(compgen -W "list allow deny op deop cmd" -- "$cur") ;;
	esac
}

_remote_complete_from() {
	local start=$1 cur hosts i
	cur=${COMP_WORDS[COMP_CWORD]}
	i=$start
	while ((i < COMP_CWORD)) && [[ ${COMP_WORDS[i]} == -* ]]; do
		i=$((i + 1))
	done
	if ((COMP_CWORD == i)); then
		hosts=''
		if command -v srv >/dev/null 2>&1; then
			hosts=$(srv get hosts '' 2>/dev/null || true)
		fi
		mapfile -t COMPREPLY < <(compgen -W "-p --parallel all $hosts" -- "$cur")
		return 0
	fi
	local next=$((i + 1))
	[[ ${COMP_WORDS[next]:-} == -p || ${COMP_WORDS[next]:-} == --parallel ]] && next=$((next + 1))
	if ((COMP_CWORD == next)); then
		mapfile -t COMPREPLY < <(compgen -W "sudo box srv" -- "$cur")
		return 0
	fi
	if [[ ${COMP_WORDS[next]} == sudo ]]; then
		next=$((next + 1))
		if ((COMP_CWORD == next)); then
			mapfile -t COMPREPLY < <(compgen -W "box srv" -- "$cur")
			return 0
		fi
	fi
	case ${COMP_WORDS[next]:-} in
		srv) _srv_complete_from $((next + 1)) ;;
		box) _box_complete_from $((next + 1)) ;;
	esac
}

_srv_complete() { _srv_complete_from 1; }
_box_complete() { _box_complete_from 1; }
_remote_complete() { _remote_complete_from 1; }

# Handle `sudo srv ...`, `sudo box ...`, `sudo remote ...` even when
# bash-completion is not installed on minimal servers.
_sudo_srv_complete() {
	local i=1 cur=${COMP_WORDS[COMP_CWORD]}
	while ((i < COMP_CWORD)) && [[ ${COMP_WORDS[i]} == -* ]]; do
		case ${COMP_WORDS[i]} in
			-u | -g | -h | -p | -C) i=$((i + 2)) ;;
			*) i=$((i + 1)) ;;
		esac
	done
	if ((COMP_CWORD == i)); then
		mapfile -t COMPREPLY < <(compgen -c -- "$cur")
		return 0
	fi
	case ${COMP_WORDS[i]:-} in
		srv) _srv_complete_from $((i + 1)) ;;
		box) _box_complete_from $((i + 1)) ;;
		remote) _remote_complete_from $((i + 1)) ;;
		*) mapfile -t COMPREPLY < <(compgen -f -- "$cur") ;;
	esac
}

complete -F _srv_complete srv
complete -F _box_complete box
complete -F _remote_complete remote
complete -p sudo >/dev/null 2>&1 || complete -F _sudo_srv_complete sudo
