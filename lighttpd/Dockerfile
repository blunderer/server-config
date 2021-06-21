#####################################################
# Dockerfile to build the webserver container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 80
EXPOSE 443

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y lighttpd \
		php \
		php-cgi \
		php-cli \
		php-common \
		php-curl \
		php-gd \
		php-imap \
		php-json \
		php-ldap \
		php-mysql \
		php-pgsql \
		php-readline \
		php-sqlite3 \
		default-mysql-client \
		php-dev \
		libmcrypt-dev \
		php-pear

# Install PHP modules
RUN pecl channel-update pecl.php.net && \
	pecl install channel://pecl.php.net/mcrypt-1.0.2

# Enable PHP modules
RUN echo "extension=mcrypt.so" >> /etc/php/7.3/cli/conf.d/20-mcrypt.ini && \
	echo "extension=mcrypt.so" >> /etc/php/7.3/cgi/conf.d/20-mcrypt.ini

# Cleanup unneeded files
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get remove -y php-dev && \
	apt-get autoremove -y && \
	apt-get clean

# Add lighttpd configuration.
RUN rm -rf /etc/lighttpd
RUN mkdir -p /etc/lighttpd/
COPY config /etc/lighttpd/

# Set UID/GID
RUN setuidgid.sh www-data www-data 1000 1000

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run lighttpd.
HEALTHCHECK --interval=1m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
