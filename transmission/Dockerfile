#####################################################
# Dockerfile to build the transmission container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 9091

ENV DEBIAN_FRONTEND="noninteractive"

# Install required packages.
RUN apt-get update && \
	apt-get install -y transmission-daemon \
		transmission-cli \
		transmission \
		wget

# Cleanup rootfs
RUN apt-get clean

# Set timezone
RUN cp /usr/share/zoneinfo/Europe/Paris /etc/localtime

# Copy configuration
COPY config/ /etc/transmission-daemon/

# Set UID/GID
RUN setuidgid.sh debian-transmission debian-transmission 1000 1000

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run transmission
HEALTHCHECK --interval=10m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
