# shellcheck shell=bash
# Shared runtime helpers for hooks: rootless Podman execution, UserNS=keep-id
# UID/GID mapping, and dual Docker/Podman container lookup/exec.
# Sourced by service hooks (hooks/prepare, hooks/lib.sh, hooks/mount, ...).

_rt_host_val() {
	local key=$1 f=${SRV_HOST_ENV:-/etc/srv/host.env} v
	[[ -r $f ]] || return 0
	v=$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*([^#]*).*$/\1/p" "$f" 2>/dev/null | tail -n 1)
	v=${v%"${v##*[![:space:]]}"}
	v=${v#"${v%%[![:space:]]*}"}
	if [[ ($v == \"*\" || $v == \'*\') && ${#v} -ge 2 ]]; then
		v=${v:1:${#v}-2}
	fi
	printf '%s\n' "$v"
}

_RT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# rt_podman_user: host user owning the rootless Podman quadlets.
rt_podman_user() {
	local u=${SRV_PODMAN_USER:-${SRV_V_unix_role:-}}
	[[ -n $u ]] || u=$(_rt_host_val unix_role)
	printf '%s\n' "${u:-${SRV_DEFAULT_UNIX_ROLE:-blunderer}}"
}

rt_podman_uid() {
	local u
	u=$(rt_podman_user)
	id -u "$u" 2>/dev/null || echo 1000
}

rt_podman_gid() {
	local u
	u=$(rt_podman_user)
	id -g "$u" 2>/dev/null || echo 1000
}

_rt_ensure_user_systemd() {
	local uid=$1
	if [[ $(id -u) == 0 && ${SRV_PODMAN_NO_SYSTEMD:-0} != 1 ]] && command -v systemctl >/dev/null 2>&1; then
		systemctl is-active -q "user@${uid}.service" || systemctl start "user@${uid}.service" >/dev/null 2>&1 || true
	fi
}

# rt_as_podman_user CMD...: run CMD in the rootless Podman user's session.
# Preserves MYSQL_PWD when set and changes cwd to / before runuser so a 0700
# caller cwd (/root) never triggers getcwd() EACCES in the target user.
_rt_run_pipe_pty() {
	local rows=24 cols=80 saved_stty='' rc=0
	local -a sd_prefix=() target_cmd=()
	while (($#)); do
		if [[ $1 == "--" ]]; then
			sd_prefix+=("$1")
			shift
			target_cmd=("$@")
			break
		fi
		sd_prefix+=("$1")
		shift
	done
	if read -r rows cols < <(stty size 2>/dev/null || true); then
		:
	fi
	[[ -n ${rows:-} && -n ${cols:-} ]] || { rows=24; cols=80; }
	saved_stty=$(stty -g 2>/dev/null || true)
	(
		trap '[[ -n $saved_stty ]] && stty "$saved_stty" 2>/dev/null || true' EXIT
		[[ -z $saved_stty ]] || stty raw -echo
		"${sd_prefix[@]}" python3 "$_RT_LIB_DIR/pipe_pty.py" "$rows" "$cols" "${target_cmd[@]}"
	) || rc=$?
	return "$rc"
}

rt_as_podman_user() {
	local scope=0
	case ${1:-} in
		--scope)     scope=1; shift ;;
		--scope-tty) scope=2; shift ;;
	esac
	local u uid home rdir dbus
	u=$(rt_podman_user)
	uid=$(id -u "$u" 2>/dev/null) || { echo "unknown Podman user: $u" >&2; return 1; }
	home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)
	home=${home:-/home/$u}
	local -a rt_env=()
	command -v crun >/dev/null 2>&1 && rt_env=(BUILDAH_RUNTIME=crun)
	if [[ $(id -u) == "$uid" ]]; then
		rdir=${SRV_PODMAN_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$uid}}
		dbus=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$rdir/bus}
		local -a env_args=("${rt_env[@]}" "HOME=$home" "USER=$u" "LOGNAME=$u" "XDG_RUNTIME_DIR=$rdir" "DBUS_SESSION_BUS_ADDRESS=$dbus")
		if ((scope > 0)) && [[ ${SRV_PODMAN_NO_SYSTEMD:-0} != 1 && -S $rdir/bus ]] &&
			command -v systemd-run >/dev/null 2>&1 &&
			! grep -q "/user@${uid}\.service/" /proc/self/cgroup 2>/dev/null; then
			if ((scope == 2)) && env "${env_args[@]}" systemd-run --user --wait --pty --collect --quiet --working-directory=/ -- true >/dev/null 2>&1; then
				env "${env_args[@]}" systemd-run --user --wait --pty --collect --quiet --working-directory=/ -- "$@"
				return
			elif env "${env_args[@]}" systemd-run --user --wait --pipe --collect --quiet --working-directory=/ -- true >/dev/null 2>&1; then
				if ((scope == 2)); then
					_rt_run_pipe_pty env "${env_args[@]}" systemd-run --user --wait --pipe --collect --quiet --working-directory=/ -- "$@"
				else
					env "${env_args[@]}" systemd-run --user --wait --pipe --collect --quiet --working-directory=/ -- "$@"
				fi
				return
			fi
		fi
		env "${env_args[@]}" "$@"
		return
	fi
	rdir=${SRV_PODMAN_RUNTIME_DIR:-/run/user/$uid}
	dbus="unix:path=$rdir/bus"
	_rt_ensure_user_systemd "$uid"
	local -a run_opts=(-u "$u")
	local -a env_args=(
		"${rt_env[@]}"
		"HOME=$home" "USER=$u" "LOGNAME=$u" "PATH=$PATH"
		"XDG_RUNTIME_DIR=$rdir" "DBUS_SESSION_BUS_ADDRESS=$dbus"
	)
	if ((scope > 0)) && [[ $(id -u) == 0 && ${SRV_PODMAN_NO_SYSTEMD:-0} != 1 && -S $rdir/bus ]] &&
		command -v systemd-run >/dev/null 2>&1; then
		local -a sd_env=() e
		for e in "${env_args[@]}"; do sd_env+=(-E "$e"); done
		[[ -z ${MYSQL_PWD+x} ]] || sd_env+=(-E MYSQL_PWD)
		if ((scope == 2)) && env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS systemd-run --machine="${u}@.host" --user --wait --pty --collect --quiet --working-directory=/ -- true >/dev/null 2>&1; then
			env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS systemd-run --machine="${u}@.host" --user --wait --pty --collect --quiet --working-directory=/ "${sd_env[@]}" -- "$@"
			return
		elif env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS systemd-run --machine="${u}@.host" --user --wait --pipe --collect --quiet --working-directory=/ -- true >/dev/null 2>&1; then
			if ((scope == 2)); then
				_rt_run_pipe_pty env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS systemd-run --machine="${u}@.host" --user --wait --pipe --collect --quiet --working-directory=/ "${sd_env[@]}" -- "$@"
			else
				env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS systemd-run --machine="${u}@.host" --user --wait --pipe --collect --quiet --working-directory=/ "${sd_env[@]}" -- "$@"
			fi
			return
		fi
	fi
	if [[ -n ${MYSQL_PWD+x} ]]; then
		run_opts=(-w MYSQL_PWD -u "$u")
	fi
	(
		cd / || exit 1
		exec runuser "${run_opts[@]}" -- env "${env_args[@]}" "$@"
	)
}

# rt_exec_podman_user CMD...: replace current process with CMD as Podman user
# (preserves interactive TTYs, e.g. tmux attach in hooks/register).
rt_exec_podman_user() {
	local u uid home rdir dbus
	u=$(rt_podman_user)
	uid=$(id -u "$u" 2>/dev/null) || { echo "unknown Podman user: $u" >&2; return 1; }
	home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)
	home=${home:-/home/$u}
	if [[ $(id -u) == "$uid" ]]; then
		rdir=${SRV_PODMAN_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$uid}}
		export HOME=$home USER=$u LOGNAME=$u XDG_RUNTIME_DIR=$rdir \
			DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$rdir/bus}
		exec "$@"
	fi
	rdir=${SRV_PODMAN_RUNTIME_DIR:-/run/user/$uid}
	dbus="unix:path=$rdir/bus"
	_rt_ensure_user_systemd "$uid"
	cd / || return 1
	exec runuser -u "$u" -- env \
		"HOME=$home" "USER=$u" "LOGNAME=$u" "PATH=$PATH" \
		"XDG_RUNTIME_DIR=$rdir" "DBUS_SESSION_BUS_ADDRESS=$dbus" "$@"
}

rt_podman() {
	local -a rtopts=()
	command -v crun >/dev/null 2>&1 && rtopts=(--runtime crun)
	case ${1:-} in
		build | run) rt_as_podman_user --scope podman "${rtopts[@]}" --cgroup-manager=cgroupfs "$@" ;;
		exec)
			if [[ -t 0 && -t 1 ]]; then
				rt_as_podman_user --scope-tty podman "${rtopts[@]}" "$@"
			else
				rt_as_podman_user --scope podman "${rtopts[@]}" "$@"
			fi
			;;
		*) rt_as_podman_user podman "${rtopts[@]}" "$@" ;;
	esac
}
rt_uctl() { rt_as_podman_user systemctl --user "$@"; }

# rt_service_runtime SVC: echo "podman" for deployed SVC/current.
rt_service_runtime() {
	local cur="${SRV_STATE:-/srv/releases}/$1/current"
	[[ -d $cur/quadlet ]] && echo podman
}

rt_subid_start() {
	local file=$1 u=$2 uid=$3 line start
	if [[ -r $file ]]; then
		line=$(awk -F: -v u="$u" -v uid="$uid" '$1 == u || $1 == uid { print $2; exit }' "$file" 2>/dev/null || true)
		start=${line%%:*}
		[[ $start =~ ^[0-9]+$ ]] && { echo "$start"; return; }
	fi
	echo 100000
}

rt_subid_len() {
	local file=$1 u=$2 uid=$3 line len
	if [[ -r $file ]]; then
		line=$(awk -F: -v u="$u" -v uid="$uid" '$1 == u || $1 == uid { print $3; exit }' "$file" 2>/dev/null || true)
		len=${line%%:*}
		[[ $len =~ ^[0-9]+$ ]] && { echo "$len"; return; }
	fi
	echo 65536
}

rt_subid_ok() {
	local file=$1 u=$2 uid=$3 line start len
	[[ -r $file ]] || return 1
	line=$(awk -F: -v u="$u" -v uid="$uid" '$1 == u || $1 == uid { print $2 ":" $3; exit }' "$file" 2>/dev/null || true)
	[[ -n $line ]] || return 1
	start=${line%%:*}
	len=${line##*:}
	[[ $start =~ ^[0-9]+$ && $len =~ ^[0-9]+$ ]] || return 1
	((len >= 65536))
}

# rt_keepid_id uid|gid CONTAINER_ID -> host UID/GID under UserNS=keep-id.
rt_keepid_id() {
	local kind=$1 cid=$2 u h_uid h_id sub_start
	u=$(rt_podman_user)
	h_uid=${SRV_UNIX_UID:-$(id -u "$u" 2>/dev/null || echo 1000)}
	if [[ $kind == uid ]]; then
		h_id=$h_uid
		sub_start=${SRV_SUBUID_START:-$(rt_subid_start /etc/subuid "$u" "$h_uid")}
	else
		h_id=${SRV_UNIX_GID:-$(id -g "$u" 2>/dev/null || echo 1000)}
		sub_start=${SRV_SUBGID_START:-$(rt_subid_start /etc/subgid "$u" "$h_uid")}
	fi
	if (( cid < h_id )); then
		echo $((sub_start + cid))
	elif (( cid == h_id )); then
		echo "$h_id"
	else
		echo $((sub_start + cid - 1))
	fi
}

# rt_host_id uid|gid CONTAINER_ID -> host UID/GID under rootless Podman keep-id.
rt_host_id() {
	rt_keepid_id "$1" "$2"
}

# rt_find_container SVC _UNUSED PODMAN_NAME
# Prints a handle ("podman:<name>") if running.
rt_find_container() {
	local svc=$1 pod_name=$3 c
	[[ -d ${SRV_STATE:-/srv/releases}/$svc/current/quadlet ]] || return 0
	c=$(rt_podman inspect -f '{{.State.Running}}' "$pod_name" 2>/dev/null || true)
	[[ $c == true ]] && echo "podman:$pod_name"
}

# rt_exec [PODMAN EXEC FLAGS... --] HANDLE CMD...
rt_exec() {
	local -a opts=()
	while (($# > 0)); do
		case $1 in
			--) shift; break ;;
			-*) opts+=("$1"); shift ;;
			*) break ;;
		esac
	done
	local handle=$1; shift
	local name=${handle#podman:}
	[[ -z ${MYSQL_PWD+x} ]] || opts+=(-e MYSQL_PWD)
	rt_podman exec "${opts[@]}" "$name" "$@"
}
