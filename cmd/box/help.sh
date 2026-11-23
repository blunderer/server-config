# shellcheck shell=bash
# box help subcommand (sourced by box).

cmd_help() {
	cat <<-'EOF'
	usage: box [-q] <command> [<command>...]     (-q: only warnings and failures)

	Setup (idempotent; several can be given: box podman ssh)
	  setup        all of these, in order
	  link [DATA]  srv, box and remote in /usr/local/bin; if missing, /etc/srv/hosts.env and
	               /etc/srv/host.env linked into DATA/configs (asks which host file)
	  unlink [DATA]  remove those links (only the ones pointing here or into DATA)
	  hostname     /etc/hostname (the inventory name) and /etc/hosts (every host)
	  ipv6         the inventory's IPv6 address on this host: with ip6_gw, a boot
	               unit sets it and the default route; checks it answers
	  man          the manual pages of the containers' programs (MANPAGES in each
	               service.env), from Debian's packages, readable with man here
	  shell        the same ~/.bashrc and ~/.profile (host/shell) for root and the
	               admin account; own additions in ~/.bashrc.local, ~/.profile.local
	  resolver     free port 53 for the dns service: systemd-resolved masked, plain
	               /etc/resolv.conf (host_resolvers, else the provider's servers)
	  packages     minimal package set and Podman; tmux, git and vim config
	  podman       rootless Podman (subuid/subgid, linger, graphroot, sysctl,
	               journald, Quadlet networks and secrets)
	  apply-role-change [-n]  apply a unix_role change: rename uid 1000, strip sudo/SSH from
	               unix_role and create/preserve admin_role (-n: dry-run)
	  ssh          sshd on ssh_port (opens it next to 22 until ssh-confirm), hardening
	  ssh-trusted [ADDR]  never ban ADDR (default: your ssh address); --list, --remove ADDR
	  ssh-keys     one key pair per host (<data>/keys/ssh/id_ecdsa_<host>, created on
	               the leader): this host's in ~/.ssh of root and admin_role,
	               the others' (and ssh_clients' keys) authorized for admin_role
	  ssh-confirm  close port 22 once `ssh -p <ssh_port>` works
	  fail2ban     sshd, SMTP AUTH and repeat-offender jails
	  alerts       email alerts through the mail service (msmtp)
	  alerts-account  create the SMTP account alerts and mail test use (once, on the leader;
	                  same as: box mail user add <alert_smtp_user> --random)
	  cron         backups, database dump, certificate renewal, upgrades, health mails

	Maintenance and migration
	  backups pause|resume|status   stop/restart backups, replication and certificate renewal here
	  data push [OPT...] [HOST...]   copy the data folder to the other hosts now (the 03:00
	                        job); from the leader, to hosts that agree, or --force
	  data pull --from [USER@]ADDR[:PORT]   a new host's first copy of the data folder,
	                                 before box link, with your own ssh login
	  data pull [OPT...] [HOST]      copy it here from the leader (or HOST); on the leader
	                        only with --force
	  data push <host> --login --force   bootstrap a host that does not trust this one yet,
	                        with your own ssh login (agent, or a password on the terminal)
	               OPT: -n|--dry-run, -v|--verbose (list files), --no-delete, --exclude-dir DIR,
	                    --force; then -- RSYNC_OPTION... (e.g. -- -v --progress)
	Day to day
	  go                    cd to the server-config repository (realpath of box)
	  login [-s [NAME|PATH]]  cache sudo for this session; with -s, also load
	                        <data>/keys/ssh/id_ecdsa_<name> (default: lenderer) into a
	                        session-scoped ssh-agent (cleared on logout or disconnect)
	  logout                clear sudo cache and stop the session ssh-agent
	  mail trace <address|queue-id> [--since TIME]   every log line of the matching
	                        messages, in order, and what became of each
	  mail test [ADDRESS]   send through 587 (alerts account) and trace it to delivery
	  mail config           edit the forwarding table, then the senders table (which login
	                        may send as which address) in vim, each checked right after
	                        its edit; then postfix reloads them (local, like user)
	  mail user list | add|passwd <name> [--random] | del <name>   SMTP accounts of this
	                        host's data folder (local: do it on the leader, its push
	                        replaces the others); for the alerts account (alert_smtp_user,
	                        when alert_email is set), the password also goes to msmtp's file
	  dns show NAME [TYPE...]   every name server's answer side by side, and a public one
	  tls [HOST[:PORT]]     the certificate clients get (default: this host on 443, 465,
	                        587, over IPv4 and IPv6)
	  ban list | unban ADDR | why ADDR   fail2ban's bans, lifting one, the lines behind it
	  distdeb [--all]       what differs from a fresh Debian install plus box's files:
	                        unowned and changed files, leftovers, foreign and obsolete
	                        packages, old kernels' modules, extra apt sources, cron (reports only)
	  keys [list]           the long-lived keys (dkim, srs, acme, tsig, websso, ssl): id, age, state
	  keys sync [--restart] sync Podman secrets from <data>/keys (--restart restarts drifted)
	  keys new dkim <domain> | websso [<client_id>]   a new DKIM key, or set up Google SSO
	  keys rotate <type> [name]     add/replace a key (dkim, srs, acme, tsig, websso)
	  keys delete <type> [name] <id>   remove an old key (dkim, srs, acme)
	  keys show dkim <folder> <id> | websso   show a key's records or settings
	  keys help <type>              the procedure for a type of key
	  ssl-renew [-f]        renew the certificate now, on the leader (-f: even when
	                        not due); what cron runs daily, shown on the terminal
	  peer-health           check the other hosts' services from outside (ssh, dns,
	                        smtp 25/587, https), alert when that changes (cron, every 15 min)
	  smtp-health           keep in this host's smtp.blunderer.org only the hosts of
	                        smtp= that work (STARTTLS, login; cron, every 5 minutes)
	  minecraft list | allow|deny <gamertag> | op|deop <gamertag> | cmd <command>
	                        the Minecraft players (allow list of Microsoft accounts)

	  migrate <from> <to>   on the leader: point the websites from one host to another
	                        (inventory names; asks for checks first)
	  leader <host>         on the leader: hand the leader role to another host
	  leader --force <host> on <host>, when the leader is down: take over

	Checks
	  check [--local]  folders, files, ownership, containers, podman, ssh, fail2ban, disk, clock
	                   (--local skips external DNS and IPv6 network checks)
	  audit        drift from the repository (and which command fixes it), ports,
	               services, extra packages, accounts

	Used by cron
	  upgrade      apt upgrade
	  run <name> <cmd...>   run a job: log to the journal, alert when it fails
	  watch        alert on check failures and needed reboots (drift: weekly report)
	  report       weekly status email
	  alert <subject> < body   send an alert; alert-test sends a test one

	Values come from the host env file (SRV_HOST_ENV, default /etc/srv/host.env).
	SRV_YES=1 answers yes to confirmations.
	EOF
}
