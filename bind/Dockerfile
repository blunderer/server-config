#####################################################
# Dockerfile to build the DNS container image.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
MAINTAINER Tristan Lelong

EXPOSE 53

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y supervisor \
		bind9 \
		bind9utils \
		bind9-host && \
	apt-get clean

# Copy configuration
RUN rm -rf /etc/bind
COPY config/ /etc/bind/
COPY supervisord.conf /etc/default/

# Prepare rootfs
RUN mkdir -p /var/run/named && \
	chmod 775 /var/run/named && \
	chown root:bind /var/run/named

# Set UID/GID
RUN setuidgid.sh bind bind 1000 1000

# Run bind.
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
