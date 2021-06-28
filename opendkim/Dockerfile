#####################################################
# Dockerfile to build the DKIM/ARC container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 12301
EXPOSE 12302

ENV DEBIAN_FRONTEND="noninteractive"
ENV OPENARC_MIRROR="https://download.opensuse.org/repositories/home:/andreasschulze/Debian_10"

# Install required packages
RUN apt-get install -y gnupg ca-certificates

# Add extra source required for openarc
COPY openarc.pubkey /tmp/
RUN echo "deb $OPENARC_MIRROR /" > /etc/apt/sources.list.d/openarc.list && \
	apt-key add /tmp/openarc.pubkey

# Fix openarc install error
RUN mkdir /etc/service/

# Install required packages
RUN apt-get update && \
	apt-get install -y supervisor \
		opendkim \
		openarc \
		opendkim-tools

# Cleanup rootfs
RUN apt-get remove -y gnupg && \
	apt-get autoremove -y && \
	apt-get clean

# Set timezone
RUN cp /usr/share/zoneinfo/Europe/Paris /etc/localtime

# Copy configuration
RUN mkdir -p /var/run/opendkim/ && \
	mkdir -p /var/run/openarc/ && \
	rm /etc/opendkim.conf
COPY config/ /etc/opendkim/
COPY supervisord.conf /etc/default/

# Set UID/GID
RUN setuidgid.sh opendkim opendkim 1000 1000
RUN usermod -a -G openarc opendkim

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run opendkim
HEALTHCHECK --interval=5m --timeout=30s --retries=3 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
