# Unbound, a recursive resolver for the mail containers only (on the srv
# network, never published). It resolves from the root servers itself, so
# DNS blocklists (Spamhaus) see this host's own address instead of a shared
# resolver they refuse to answer. dns-root-data: root hints and trust anchor.
FROM docker.io/library/debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io unbound dns-root-data \
	&& rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 srv-unbound /usr/local/bin/srv-unbound
ENTRYPOINT ["/usr/local/bin/srv-unbound"]
