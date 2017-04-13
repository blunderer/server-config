#####################################################
# Dockerfile to build the webserver container image.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
MAINTAINER Tristan Lelong

EXPOSE 80
EXPOSE 443

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y lighttpd \
		php5 \
		php5-cgi \
		php5-cli \
		php5-common \
		php5-curl \
		php5-gd \
		php5-imap \
		php5-json \
		php5-ldap \
		php5-mcrypt \
		php5-mysql \
		php5-pgsql \
		php5-readline \
		php5-sqlite \
		mysql-client-5.5 && \
	apt-get clean

# Add lighttpd configuration.
RUN rm -rf /etc/lighttpd
RUN mkdir -p /etc/lighttpd/
COPY config /etc/lighttpd/

# Set UID/GID
RUN setuidgid.sh www-data www-data 1000 1000

# Run lighttpd.
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
