# The Antigravity CLI (agy) and the tools an agent commonly needs, running as
# agy (uid 1000, the data folder's owner, so what it writes is yours), which
# may become root in the container with sudo, without a password.
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io \
		bind9-dnsutils \
		ca-certificates \
		curl \
		fd-find \
		file \
		gh \
		git \
		jq \
		less \
		openssh-client \
		openssl \
		patch \
		procps \
		python3 \
		ripgrep \
		rsync \
		shellcheck \
		shfmt \
		sqlite3 \
		sudo \
		tmux \
		tree \
		yamllint \
	&& rm -rf /var/lib/apt/lists/*

RUN useradd --uid 1000 --create-home --shell /bin/bash agy \
	&& install -d -o agy -g agy /work \
	&& echo 'agy ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/agy \
	&& chmod 0440 /etc/sudoers.d/agy \
	&& visudo -cf /etc/sudoers.d/agy

# Google's installer (it checks the download's checksum). It installs the
# current release: srv deploy rebuilds, so a deploy also updates agy; agy owns
# /opt/agy so in-place remote updates work too.
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash -s -- --dir /opt/agy \
	&& bin=$(find /opt/agy -type f -name agy -perm -u+x | head -n 1) \
	&& test -n "$bin" \
	&& ln -s "$bin" /usr/local/bin/agy \
	&& chown -R agy:agy /opt/agy \
	&& agy --version
COPY --chmod=0755 srv-agy /usr/local/bin/srv-agy

USER agy
WORKDIR /work
CMD ["srv-agy"]
