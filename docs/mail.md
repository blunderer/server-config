# Mail

The mail service receives mail for blunderer.org, lelong.xyz (with n. and
rion.), libroxml.net and libroxml.com, and forwards it according to
the forwarding table, `<data>/configs/mail/virtual` (mostly to Gmail; edited
with `box mail config`, docs/runbooks.md). Authenticated users
can also send through it (ports 587 and 465).

## Containers

| Container   | Role                                                        |
|-------------|-------------------------------------------------------------|
| `postfix`   | SMTP; forwards; SPF annotation (policyd-spf, never rejects) |
| `saslauthd` | SMTP AUTH against `<data>/users/postfix/shadow`             |
| `opendkim`  | signs mail from authenticated users, verifies incoming mail |
| `openarc`   | verifies existing ARC sets and seals every message          |
| `postsrsd`  | Sender Rewriting Scheme lookups                             |
| `rspamd`    | spam score of incoming mail (milter); tags, or rejects from `spam_reject` |

The queue is in the `mail-spool` folder under `volumes_dir` (default `/home/volumes`), shared by every release.

## Forwarding to Gmail without failing SPF or DKIM

**SRS.** SPF checks the envelope sender against the sending IP. A forwarded
message from alice@example.com arrives at Gmail from our IP, which
example.com's SPF does not list. postsrsd rewrites the envelope sender to
`SRS0=hash=tt=example.com=alice@blunderer.org`, so SPF is checked against
blunderer.org and passes. Bounces to that address are decoded back to Alice;
the hash (secret in `<data>/keys/postsrsd/`, the same on every host) stops
anyone from using it as a relay.

**DKIM survives** because only envelope addresses are rewritten
(`sender_canonical_classes = envelope_sender`), and
`disable_mime_output_conversion = yes` keeps postfix from re-encoding bodies.

**ARC** records what we verified on arrival. policyd-spf and opendkim add
`Authentication-Results` (authserv-id = `server_name`), and OpenARC seals
them with the blunderer.org key (selector `mail`, the DKIM key, so no DNS
change). The old `openarc.conf` had `Mode v`: it never sealed anything.

## Sending through the servers: smtp.blunderer.org

Mail clients that send through our servers (Gmail's "Send mail as", a phone)
use one name, `smtp.blunderer.org`, port 587 (STARTTLS) or 465. It has one
address (A, and AAAA when the host has one) per mail host listed in
`smtp=` in the inventory, as long as that host works the way Gmail
uses it:

```
smtp="orion lyra vega"
```

`box smtp-health` runs every 5 minutes on every host running dns and does what Gmail
does with each host (two tries, 5 s apart): connect to port 587, STARTTLS
with a certificate that must be valid for `smtp.blunderer.org`, then log in
with the alerts account (`alert_smtp_user`, its password from
`<data>/keys/alerts/smtp_password`; `lib/smtp_login.py`). A host where any
step fails is taken out of the name; it is put back as soon as it works
again. With every host failing, it keeps them all rather than emptying the
name. Each change of the set sends one alert naming the step that failed
("lyra (198.51.100.20): STARTTLS: certificate verify failed: Hostname
mismatch"). On a host without alerts set up, it only checks that port 587
greets.

The hosts of the inventory are never banned by fail2ban on each other
(`box fail2ban` adds their addresses to `ignoreip`): a wrong alerts password
on one host must not get the name servers banned there every 5 minutes.

The name lives in its own dynamic zone, `smtp.blunderer.org` (delegated from
blunderer.org to the same name servers, TTL 60 s). Unlike the other zones,
it is not copied from the leader: **every name server is its primary** and
keeps its own copy, updated by its own `box smtp-health` with a TSIG key of
its own (`<data>/keys/dns/smtp-tsig.key`, created by `srv deploy dns`, not
replicated) that may only change that name's records. Every name server
checks the same mail hosts, so the copies agree, give or take the 5 minutes
between checks. When a host dies, the leader included, its name server stops
answering and every surviving one drops its address on its own: within about
6 minutes (5 for the check, 1 for caches), clients get only the healthy
hosts. `box check` on each host warns while its copy leaves a host out.

One outage sends one alert, not one per name server: the leader sends them,
or, when the leader is a mail host found down, the first working host of
`smtp=`.

Set `smtp=` only once every host listed in `ns=` runs the srv `dns`
service: each of them must then serve the zone. Until then, give the name
static records on the old master (`smtp 300 IN A <address>`, one per working
host) and leave `smtp=` unset; the srv zone then renders no delegation and no
zone.

For a host to be listed, it must:

- accept the same SMTP logins and senders, the alerts account included (the
  srv hosts get them with the data folder; an old-stack host without the
  alerts account is left out);
- serve a certificate valid for `smtp.blunderer.org` (the srv certificate is
  a wildcard; on the old stack, add the name to getssl's SANS);
- not list `smtp` in its `<host>_names` (`srv` refuses it: the name is its
  own zone).

In Gmail: Settings, Accounts, "Send mail as", edit the address, SMTP server
`smtp.blunderer.org`, port 587, same login.

## Spam filtering (rspamd)

Mail that passes the blocklists goes through rspamd (a milter, between
opendkim and openarc), which scores it: SPF, DKIM and DMARC results,
headers, content, links (phishing, URL blocklists), fuzzy hashes of known
spam. Our own users' mail (SMTP AUTH, alerts) and mail made on the server
are never scored as spam (`config/rspamd/settings.conf`).

**Tag only, to start.** Without `spam_reject` in the host files, rspamd
rejects nothing: it adds `X-Spamd-Result` (score and rules) and
`X-Spam-Status` (yes from 6) to every message, and logs one line per
message. Watch what scores high for a week or two:

```
journalctl -t rspamd --since -1d --no-pager | grep -oE '\(default: [TF] \([^)]*\): \[[0-9.-]+/' | sort | uniq -c
journalctl -t rspamd --since -7d --no-pager | grep -E '\[(1[5-9]|[2-9][0-9])\.[0-9]+/'   # what 15 would reject
```

`box mail spam --since -14d` lists them (score, sender, recipient, client,
main rules), and `box mail spam --min 15` what 15 would reject. In Gmail,
"Show original" shows the same headers on what got through.

**Reject.** Set the score in the inventory (`hosts.env`, so every mail host
agrees), push it, and deploy mail on each mail host:

```
spam_reject=15
```

From that score up, the message is refused during the SMTP conversation
(550): the sender's server returns it to the sender, nothing is accepted
and dropped, and Gmail never sees it, so it cannot count against our
domain. Lower it once the logs show no legitimate mail near it. If rspamd
is down, mail flows unscored (`milter_default_action = accept`).

No redis: greylisting, Bayes learning and rate limits stay off. They can be
added later with a redis container.

## DMARC reports: kept on the servers

Every domain's DMARC record sends aggregate reports (`rua=`) to
`dmarc-reports@blunderer.org`, a dedicated address: `admin@blunderer.org`,
the earlier one, is also the zones' SOA contact and keeps its forwarding.
The reports are XML for machines, not worth Gmail's quota, so postfix keeps
them in a Maildir on the host that received them:

- `config/postfix/dmarc_alias` maps the address to `reports@dmarc.invalid`,
  an internal mailbox domain (`dmarc_mailbox`, delivered by postfix's
  `virtual` agent as uid 5000). It is searched before the forwarding table,
  so a catch-all there does not take it, and nothing else changes route.
- The Maildir is `/var/mail/reports/dmarc/` in the `mail-reports` folder
  under `volumes_dir` (default `/home/volumes`, off the root partition and kept
  across releases), not the replicated data folder. Each mail host has the
  reports it received.
- `srv hook mail prune-reports` (cron, daily) deletes those older than 90
  days.

Reading them: `srv exec mail postfix ls -lt /var/mail/reports/dmarc/new`,
then `srv exec mail postfix cat <file>` (the report is a zip or gzip
attachment).

lelong.xyz, libroxml.net and libroxml.com send theirs to the same address:
a report address in another domain must be authorized by that domain, so
blunderer.org has `<domain>._report._dmarc TXT "v=DMARC1"` for each of them
(without it, reporters skip the address). A new mail domain needs both: its
`rua=` and that record.

## Spoofing

- `InternalHosts` (OpenDKIM, OpenARC) is localhost only. The old file had
  `*`, so every host on the internet counted as internal: mail claiming to be
  from us was signed with our key on its way to Gmail.
- `own_domains`: unauthenticated clients may not use our domains as envelope
  sender (`check_sender_access`). This stops most "spam from my own address".
  It also rejects mail that goes out through another provider with one of our
  addresses as envelope sender and comes back to us. Mail you send through
  this server after authenticating is not affected.
- **Senders table**: a logged-in client may only use the envelope senders its
  login owns in `<data>/configs/mail/senders` (`smtpd_sender_login_maps`
  with `reject_authenticated_sender_login_mismatch`):
  ```
  contact@blunderer.org   tristan
  @lelong.xyz             tristan
  alerts@blunderer.org    alerts
  ```
  The logins are the bare names (`tristan`), as postfix logs them in
  `sasl_username=` (`box mail trace`); a client should log in with the bare
  name too, since `tristan@lelong.xyz` would be another owner. An address
  can have several logins (`tristan, jane`); `@domain` covers the whole
  domain; an unlisted sender is refused ("Sender address rejected: not
  owned by user"), foreign domains included. Without it, any login could
  send as any of our addresses, DKIM-signed. Only the envelope sender is
  checked, not the `From:` header. The first table (created by the first
  deploy) lets every login use all our domains; narrow it with
  `box mail config`. `box check` warns about a login that may send as
  nothing (it can log in, but every message is refused).
- Never add the Docker network to `mynetworks` (see the comment in
  `main.cf`).

## DNS blocklists (Spamhaus) and the resolver

`smtpd_recipient_restrictions` queries Spamhaus `zen` (IP) and `dbl` (domain).
Two things matter:

- **Return codes are pinned** (`zen.spamhaus.org=127.0.0.[2..11]`,
  `dbl.spamhaus.org=127.0.1.[2..99]`). A blocklist that cannot answer returns
  an error in `127.255.255.x`; without the pin postfix treats that as a
  listing and rejects every mail. Pinned, an error means "not listed" and mail
  keeps flowing — a blocklist outage can never again bounce all mail.
- **The mail containers use their own resolver.** Spamhaus's free zones
  refuse queries arriving through big shared resolvers (OVH's, Google,
  Cloudflare: reply `Error: open resolver`). So the mail service runs Unbound
  (`resolver` container, `config/unbound.conf`), which resolves from the root
  servers itself: Spamhaus sees this host's own address. postfix (with
  policyd-spf), OpenDKIM and OpenARC use it through `dns:`; container names
  still resolve through Docker's embedded DNS.

The resolver has a fixed address on the `srv-mail` network, `mail_resolver_ip`
(default `.253` of `srv_mail_subnet`), is never published, and answers only that
network: it is not an open resolver. Two releases never run it at once, since
deploy and rollback stop the old release before starting the new one.

Spamhaus's free use is for low volumes and non-commercial use, which a
personal server is. To check that the blocklists answer, from the host:

```
srv exec mail postfix sh -c 'getent hosts 2.0.0.127.zen.spamhaus.org'
```

`127.0.0.2` (and other `127.0.0.x`) is the test listing: the blocklists work.
`127.255.255.x` means Spamhaus refused the query: the pin keeps mail flowing,
but there is no protection until that is fixed.

## MX and mail names

The MX records of all four zones come from `mx=` in the inventory: targets in
order of preference, priority 100, 200, 300... Each target is a host
(`orion`) or one of its names (`mail0`). The default, `mx="mail0 mail1"`,
gives the historical records.

A mail host's own name (postfix's greeting, the name its reverse DNS must
match, `box check` "reverse and forward names") is the name it has in
`mx=`; a host not in `mx=` uses its first `mailN` name, else
`<host>.blunderer.org`.

`mail0` and `mail1` stay in `orion_names`/`lyra_names` either way: they are
what mail clients and the alert account use to send through the server, and
what the certificate covers.

### Switching the MX to host names (after the migration)

1. At the hosting provider, set each mail host's reverse DNS (IPv4 and
   IPv6) to `<host>.blunderer.org`.
2. In the inventory: `mx="orion lyra vega"` (or the order you want).
3. On the leader: `srv deploy dns`, check `dig MX blunderer.org`.
4. On each mail host: `srv deploy mail`, `box check` (reverse and
   forward names `ok`), then send a test to Gmail.

Back: remove `mx=` (or `mx="mail0 mail1"`), set the reverse names back to
`mailN.blunderer.org`, the same deploys.

The host names do not need to be in the certificate: servers delivering
mail do not check it, and clients keep using `mail0`. The vpn service's
`SERVERURL` follows the same name; existing WireGuard clients keep the
endpoint they were given.

## IPv6

A host's IPv6 address goes in the inventory as `<host>_ip6`. With it:

- its names (`orion`, `ns0`, `mail0`...) get AAAA records next to their A
  records, and the SPF `mx` mechanism covers the mail hosts' IPv6 addresses;
- its postfix sends over IPv6 when the receiver has it
  (`smtp_address_preference = any`). Without it, postfix sends over IPv4
  (`ipv4`), since Gmail rejects an IPv6 source whose reverse name does not
  resolve back to it.

The reverse names are set at the hosting provider, for the IPv4 and the IPv6
address: the host's mail name (see "MX and mail names"). Set the IPv6
reverse **before** adding `<host>_ip6`, then `srv deploy dns` on the leader
and `srv deploy mail` on that host. `box check` verifies both names on
mail hosts ("reverse and forward names").

Not covered: AAAA records for the websites, which still point at `web_ip`
only.

## Testing (on vega first)

1. Temporarily allow vega in SPF (`spf_extra=" ip4:<ip> ip6:<ip6>"` in the
   leader's host file, then `srv deploy dns` there): vega is not an MX, so
   the `mx` mechanism does not cover it.
2. From another machine, send to a forwarded address directly through the
   vega, e.g. with swaks:
   ```
   swaks --server <vega-ip> --to tristan@blunderer.org --from someone@gmail.com
   ```
3. Watch it with `box mail trace tristan@blunderer.org --since -10min`:
   postsrsd lookups, opendkim/openarc results, the relay to Gmail.
4. In Gmail, open the message, "Show original":
   - `SPF: PASS` with `smtp.mailfrom=...@blunderer.org` (an SRS0= address),
   - `ARC-Seal: i=1; ... d=blunderer.org; s=mail`,
   - `ARC-Authentication-Results` listing `spf=pass` for the original sender
     and `dkim=pass` for its domain (when it was DKIM-signed).
5. Submission: `box mail test` sends through 587 with the alerts account and
   traces the message. Also try a mail client with SMTP AUTH on 587
   (STARTTLS) and 465 (implicit TLS; the old server spoke plain SMTP on 465).
   `DKIM: PASS` for our domain at the receiving end.
6. Spoofing: `swaks --server <ip> --to tristan@blunderer.org --from x@blunderer.org`
   must be rejected with "Not authorized to send mail as this domain".

If `ARC-Authentication-Results` lacks the SPF result, the policy service
header is not visible to the milters: OpenDKIM's DKIM result is still sealed,
which is what matters most for Gmail.

## Adding a mail domain

1. `virtual_alias_domains` in `main.cf`; addresses with `box mail config`
   (it refuses addresses of domains not listed there, so deploy first), and
   the logins that may send as the new domain in the senders table (same
   command, second file).
2. `own_domains` (and the `.domain` line for subdomains).
3. `domains` in `postsrsd.conf`.
4. A DKIM key: `box keys new dkim <domain>` (on the leader) creates it and
   prints the KeyTable and SigningTable lines and the zone's TXT record.
5. Zone: MX, SPF, DMARC (`p=quarantine; sp=quarantine;`).
6. `srv deploy mail`.

## DMARC enforcement

All zones publish `p=quarantine; sp=quarantine` with `rua=` aggregate reports
to `dmarc-reports@blunderer.org`. Once reports stay clean across every mail
flow, `p=reject; sp=reject` can be published. Rejecting incoming mail that
fails the *sender's* DMARC policy needs an OpenDMARC milter after OpenDKIM, in
non-rejecting mode first.

## Rotating DKIM keys (and 2048-bit keys)

The older DKIM keys are 1024-bit (still accepted, no longer recommended).
`box keys rotate dkim <folder>` makes a 2048-bit key under a new selector
(`sYYYYMM`) and prints the steps: the TXT records to add, `box data push`,
the KeyTable lines (and `openarc.conf` for blunderer.org) to switch once DNS
serves the key, the deploys. A week later, `box keys delete dkim <folder>
<old id>` deletes the old key (refused while the KeyTable or openarc still
uses it) and lists its records to remove. See docs/operations.md, "Keys".
