#####################################################
# Dockerfile to build the DKIM container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 12301

ENV DEBIAN_FRONTEND="noninteractive"

# Install required packages
RUN apt-get update && \
	apt-get install -y supervisor \
		opendkim \
		opendkim-tools && \
	apt-get clean

# Set timezone
RUN cp /usr/share/zoneinfo/Europe/Paris /etc/localtime

# Copy configuration
RUN mkdir -p /var/run/opendkim/
COPY config/ /etc/opendkim/
COPY supervisord.conf /etc/default/

# Set UID/GID
RUN setuidgid.sh opendkim opendkim 1000 1000

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run opendkim
HEALTHCHECK --interval=5m --timeout=30s --retries=3 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
