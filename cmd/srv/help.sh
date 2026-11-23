# shellcheck shell=bash
# srv help subcommand (sourced by srv).

cmd_help() {
	cat <<-'EOF'
	usage: srv [-y] [-v] <command> [args]

	Release lifecycle
	  build [-p] [-j N] [-v] <svc|all>   pull and build images only (-p: parallel services)
	  deploy [-v] [--commit] <svc|all>   pull/build, render, shift volumes; switch release
	  rollback <svc>        swap current and previous release (run again to roll forward)
	  commit <svc|all>      remove the previous release's containers, prune old releases
	  discard <svc|all> [rel...]  remove releases never switched to (declined or failed
	                        deploys): containers, built images, folders
	  status [svc]          current/previous release and container health per service
	  stats [--no-stream] [svc...]   live CPU, memory, network, disk per container

	Day to day
	  logs <svc> [args]     container logs (default: -f --tail 100)
	  shell <svc> [ctr]     interactive shell in a container of the current release
	  exec <svc> [ctr|--] cmd   run a command in a container of the current release
	  podman <args...>      run podman as the rootless unix_role user
	  uctl <args...>        run systemctl --user as the rootless unix_role user
	  stop <svc>            stop the current release (stays stopped across reboots)
	  start <svc>           start it again
	  restart <svc>         restart the current release's containers
	  reload <svc>          reload configuration in place (e.g. after an SSL renewal)
	  diff <svc>            diff previous vs current release (rendered config)
	  pending <svc|all>     what a deploy would change: config diff, images to replace
	  hook <svc> <name> [arg...]   run services/<svc>/hooks/<name> (e.g. srv hook db dump)
	  hook list [svc|all]   each service's hooks: when they run, what they do

	Setup and checks
	  init-host             create Podman Quadlet networks and volumes dir
	  services              list services enabled on this host, in dependency order
	  render <svc> [dir]    render a service to a directory, without deploying
	  render-file <in> <out>  render one template file with this host's values
	  get <key> [default]   print a host value (<host>_<key> reads configs/<host>.env)
	  requirements          files/folders the enabled services expect (box check)
	  check [svc...]        render and validate services (used by CI)

	Options
	  -y                    answer yes to every confirmation (SRV_YES=1)
	  -v, --verbose         show raw podman pull/build output instead of progress bar (SRV_VERBOSE=1)
	Environment
	  SRV_HOST_ENV  host values (default /etc/srv/host.env)
	  SRV_STATE     release directory (default /srv/releases)
	  SRV_KEEP      release directories to keep per service (default 3)
	EOF
}
