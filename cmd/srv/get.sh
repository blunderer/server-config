# shellcheck shell=bash
# srv get subcommand (sourced by srv).

# peer_host_env HOST: per-host env file for HOST under <data_dir>/configs
# (<HOST>.env, else a *.env file with host=HOST), empty when there is none.
peer_host_env() {
	local configs=${HOST[data_dir]}/configs f
	if [[ $1 != hosts && -r $configs/$1.env && $(readlink -f "$configs/$1.env") != "${HOST[hosts_file]}" ]]; then
		printf '%s\n' "$configs/$1.env"
		return 0
	fi
	for f in "$configs"/*.env; do
		[[ ${f##*/} == hosts.env || $(readlink -f "$f") == "${HOST[hosts_file]}" || ! -r $f ]] && continue
		if grep -qE "^[[:space:]]*host=['\"]?$1['\"]?[[:space:]]*$" "$f" 2>/dev/null; then
			printf '%s\n' "$f"
			return 0
		fi
	done
}

# cmd_get KEY [DEFAULT]: print HOST[KEY]. When KEY is unset and starts with
# <host>_ (for a host in hosts= or this host), resolve the unprefixed key from
# this host's loaded values or from <data_dir>/configs/<host>.env.
cmd_get() {
	local key=${1:?usage: srv get <key> [default]}
	load_host
	if [[ -n ${HOST[$key]+set} ]]; then
		printf '%s\n' "${HOST[$key]}"
		return 0
	fi
	local h sub='' env='' rc=1 hosts_file=${HOST[hosts_file]}
	for h in ${HOST[hosts]} ${HOST[host]}; do
		[[ $key == "${h}_"* ]] || continue
		sub=${key#"${h}_"}
		[[ -n $sub ]] || break
		if [[ $h == "${HOST[host]}" ]]; then
			if [[ -n ${HOST[$sub]+set} ]]; then
				printf '%s\n' "${HOST[$sub]}"
				return 0
			fi
		else
			env=$(peer_host_env "$h")
			if [[ -n $env ]]; then
				set +e
				(
					set -e
					# shellcheck disable=SC2030,SC2034 # subshell-local overrides read by load_host
					SRV_HOST_ENV=$env
					# shellcheck disable=SC2034 # read by load_host
					SRV_HOSTS_ENV=$hosts_file
					HOST=()
					load_host
					[[ -n ${HOST[$sub]+set} ]] || exit 1
					printf '%s\n' "${HOST[$sub]}"
				)
				rc=$?
				set -e
				if ((rc == 0)); then
					return 0
				fi
			fi
		fi
		break
	done
	if [[ $# -ge 2 ]]; then
		printf '%s\n' "$2"
	elif [[ -n $env ]]; then
		# shellcheck disable=SC2031 # outer SRV_HOST_ENV is unchanged
		die "$key is not set in $SRV_HOST_ENV (nor $sub in $env)"
	else
		# shellcheck disable=SC2031 # outer SRV_HOST_ENV is unchanged
		die "$key is not set in $SRV_HOST_ENV"
	fi
}
