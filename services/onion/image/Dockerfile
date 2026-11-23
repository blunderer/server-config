# Tor onion service. Tor itself only: the site is served by the web service.
FROM docker.io/library/debian:trixie-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io tor ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

# The onion keys in <data>/keys/tor belong to uid 1000 (old images); run as it.
RUN mkdir -p /var/lib/tor/hs \
	&& chown -R 1000:1000 /var/lib/tor \
	&& chmod 700 /var/lib/tor

COPY --chmod=0755 srv-tor-health /usr/local/bin/srv-tor-health
USER 1000:1000
ENTRYPOINT ["tor", "-f", "/etc/tor/torrc"]
