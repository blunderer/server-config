# PHP-FPM for the websites: Debian trixie's prebuilt PHP 8.4 packages
# (no source compilation; builds in seconds and shares debian:trixie-slim
# with the other custom images).
FROM docker.io/library/debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o DPkg::Options::=--force-unsafe-io \
		php8.4-fpm \
		php8.4-cli \
		php8.4-mysql \
		php8.4-gd \
		php8.4-zip \
		php8.4-intl \
		php8.4-opcache \
	&& rm -rf /var/lib/apt/lists/* \
	&& ln -s /usr/sbin/php-fpm8.4 /usr/local/sbin/php-fpm \
	&& sed -i \
		-e 's|^pid = .*|pid = /tmp/php-fpm.pid|' \
		-e 's|^error_log = .*|error_log = /proc/self/fd/2|' \
		-e 's|^;\?daemonize = .*|daemonize = no|' \
		/etc/php/8.4/fpm/php-fpm.conf \
	&& sed -i \
		-e 's|^listen = .*|listen = 127.0.0.1:9000|' \
		-e 's|^listen\.owner = |;listen.owner = |' \
		-e 's|^listen\.group = |;listen.group = |' \
		/etc/php/8.4/fpm/pool.d/www.conf \
	&& printf '%s\n' \
		'[www]' \
		'access.log = /proc/self/fd/2' \
		'clear_env = no' \
		'catch_workers_output = yes' \
		'decorate_workers_output = no' \
		>/etc/php/8.4/fpm/pool.d/zz-srv.conf \
	&& php-fpm -t \
	&& php -m

USER 1000:1000
EXPOSE 9000
CMD ["php-fpm", "-F"]
