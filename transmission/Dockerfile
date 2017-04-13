#####################################################
# Dockerfile to build the transmission container image.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
MAINTAINER Tristan Lelong

EXPOSE 9091

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y transmission-daemon \
		transmission-cli \
		transmission && \
	apt-get clean

# Copy configuration
COPY config/ /etc/transmission-daemon/

# Set UID/GID
RUN setuidgid.sh debian-transmission debian-transmission 1000 1000

# Run transmission
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
