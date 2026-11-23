# OpenARC milter, built from the maintained fork (no Debian package for it).
# Renovate tracks OPENARC_VERSION through the GitHub tags.
FROM docker.io/library/debian:trixie-slim AS builder

# renovate: datasource=github-tags depName=flowerysong/OpenARC
ARG OPENARC_VERSION=v1.3.2

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io \
		ca-certificates git build-essential autoconf automake libtool pkg-config \
		libssl-dev libbsd-dev libidn2-dev libjansson-dev libmilter-dev \
	&& git clone --depth 1 --branch "$OPENARC_VERSION" https://github.com/flowerysong/OpenARC.git /tmp/openarc \
	&& cd /tmp/openarc \
	&& autoreconf -fi \
	&& ./configure --prefix=/usr/local \
	&& make -j"$(nproc)" \
	&& make install

FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io \
		libssl3t64 libbsd0 libidn2-0 libjansson4 libmilter1.0.1 netcat-openbsd \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --uid 1000 --user-group --no-create-home --shell /usr/sbin/nologin openarc

COPY --from=builder /usr/local /usr/local
RUN ldconfig && openarc -V

# OpenARC runs as uid 1000 (it shares the DKIM keys) and, like OpenDKIM,
# rejects its key as insecure when the running uid has no account.
USER openarc
ENTRYPOINT ["openarc", "-f", "-c", "/etc/srv/openarc/openarc.conf"]
