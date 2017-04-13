#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Set permissions
chown -R mysql.mysql /var/lib/mysql/

# Run mysql
exec /usr/sbin/mysqld --basedir=/usr --datadir=/var/lib/mysql \
	--plugin-dir=/usr/lib/mysql/plugin --user=mysql \
	--log-error=/var/log/mysql/error.log \
	--pid-file=/var/run/mysqld/mysqld.pid \
	--socket=/var/run/mysqld/mysqld.sock \
	--port=3306
