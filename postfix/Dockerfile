#####################################################
# Dockerfile to build the postfix container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 25
EXPOSE 465
EXPOSE 587

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y supervisor \
		postfix \
		sasl2-bin \
		telnet \
		postsrsd && \
	apt-get clean

# Copy configuration
RUN rm -rf /etc/postfix/* && \
	mkdir -p /var/lib/etc/ && \
	mkdir -p /var/spool/postfix/var/run/saslauthd && \
	echo "blunderer.org" > /etc/mailname
COPY config/ /etc/postfix/
COPY supervisord.conf /etc/default/

# Set UID/GID
RUN setuidgid.sh postfix postfix 1000 1000

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run postfix.
HEALTHCHECK --interval=1m --timeout=10s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
