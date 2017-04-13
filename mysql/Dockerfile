#####################################################
# Dockerfile to build the mysql container image.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
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

# Run mysql
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT [ "/entrypoint.sh" ]
