#####################################################
# Dockerfile to build the DNS container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 53

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y supervisor \
		bind9 \
		bind9utils \
		bind9-host \
		dnsutils && \
	apt-get clean

# Copy configuration
RUN rm -rf /etc/bind
COPY config/ /etc/bind/
COPY supervisord.conf /etc/default/

# Set UID/GID
RUN setuidgid.sh bind bind 1000 1000

# Prepare rootfs
RUN mkdir -p /var/run/named && \
	chmod 775 /var/run/named && \
	chown root:bind /var/run/named

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run bind.
HEALTHCHECK --interval=2m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
