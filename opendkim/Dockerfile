#####################################################
# Dockerfile to build the DKIM container image.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
MAINTAINER Tristan Lelong

EXPOSE 12301

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y supervisor \
		opendkim \
		opendkim-tools && \
	apt-get clean

# Copy configuration
RUN mkdir -p /var/run/opendkim/
COPY config/ /etc/opendkim/
COPY supervisord.conf /etc/default/

# Set UID/GID
RUN setuidgid.sh opendkim opendkim 1000 1000

# Run opendkim.
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
