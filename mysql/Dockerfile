#####################################################
# Dockerfile to build the mysql container image.
# This is based on custom debian stable debootstrap.
#####################################################
FROM debian:latest
MAINTAINER Tristan Lelong

EXPOSE 3306

# Install required packages
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get install -y mysql-server && \
	apt-get clean

# Create configuration
RUN install -m 755 -o mysql -g root -d /var/run/mysqld
COPY config/my.cnf /etc/mysql/

# Set UID/GID
RUN setuidgid.sh mysql mysql 1000 1000

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run mysql
HEALTHCHECK --interval=1m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
