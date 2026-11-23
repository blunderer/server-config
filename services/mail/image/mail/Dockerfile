# One image for the mail stack: postfix, saslauthd, opendkim, postsrsd and
# rspamd run as separate containers from it (one daemon per container).
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
# postsrsd comes from trixie-backports: trixie itself ships 1.10, which has no
# configuration file (-C) and no socketmap. Backports only for that package.
RUN echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections \
	&& printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' \
		'Suites: trixie-backports' 'Components: main' \
		'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' \
		>/etc/apt/sources.list.d/backports.sources \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io \
		postfix \
		postfix-policyd-spf-python \
		libsasl2-modules \
		sasl2-bin \
		opendkim \
		opendkim-tools \
		rspamd \
		netcat-openbsd \
		ca-certificates \
		postsrsd/trixie-backports \
	&& rm -rf /var/lib/apt/lists/*

# saslauthd runs in its own container; postfix reaches its socket through the
# shared /run/saslauthd, which sasl2-bin restricts to the sasl group (root:sasl
# 710). The old single container got this membership from the data folder's
# group file; here the image provides it.
RUN usermod -a -G sasl postfix

# OpenDKIM runs as uid 1000 (the DKIM keys in <data>/keys/opendkim belong to
# it). Its key safety check (RequireSafeKeys) first looks up the running
# user's name, and treats every key as insecure when that uid has no account:
# "key data is not secure: <path>", with no reason. So uid/gid 1000 must have
# a name: the package's opendkim user and group take that number.
RUN groupmod -g 1000 opendkim && usermod -u 1000 -g 1000 opendkim

# rspamd runs in the foreground as _rspamd (compose.yml): its runtime folder
# (pid file, control socket) is made by systemd on a normal install.
RUN install -d -o _rspamd -g _rspamd -m 0755 /run/rspamd

COPY --chmod=0755 srv-postfix /usr/local/bin/srv-postfix
