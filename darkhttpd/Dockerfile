#####################################################
# Dockerfile to build the webserver container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

ENV DEBIAN_FRONTEND=noninteractive

# Install required packages.
RUN echo https://deb.torproject.org/torproject.org >> /etc/apt/source.list
RUN apt-get update && \
	apt-get install -y supervisor \
		lighttpd \
		php \
		php-cgi \
		php-cli \
		php-common \
		php-curl \
		php-json \
		php-readline \
		php-sqlite3 \
		tor \
		wget

# Cleanup unneeded files
RUN apt-get remove -y php-dev && \
	apt-get autoremove -y && \
	apt-get clean

# Set timezone
RUN cp /usr/share/zoneinfo/Europe/Paris /etc/localtime

# Add configurations.
RUN rm -rf /etc/lighttpd
RUN mkdir -p /etc/lighttpd/
COPY config/lighttpd /etc/lighttpd/
RUN rm -rf /etc/tor
RUN mkdir -p /etc/tor/
COPY config/tor /etc/tor

# Set UID/GID
RUN setuidgid.sh www-data www-data 1000 1000
RUN chown -R www-data.www-data /var/lib/tor

# Resources
COPY resources/ /
COPY supervisord.conf /etc/default/
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run lighttpd.
HEALTHCHECK --interval=1m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
