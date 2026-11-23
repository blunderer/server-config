# Jellyfin on linuxserver's Ubuntu 26.04 image, with SQLitePCLRaw's bundled
# libe_sqlite3.so replaced by Ubuntu's baseline libsqlite3-0.
#
# Upstream libe_sqlite3.so is compiled with SSE4.1 instructions (blendvpd,
# roundsd) and no CPUID dispatch (SQLitePCL.raw #652, jellyfin #15148), which
# crashes Jellyfin with SIGILL at libe_sqlite3.so+0x3fbad on pre-SSE4.1 x86-64
# hosts (vega) whenever SQLite evaluates floating-point abs() -- e.g. Cast's
# idle backdrop query (sortBy=Random -> EF.Functions.Random()) and library
# scans. Ubuntu's amd64 libsqlite3-0 is pure baseline x86-64 (SSE2).
FROM lscr.io/linuxserver/jellyfin:version-12.4ubu2604@sha256:2f708001387aa9853e744a4a4d572d9970927c479c56d6c9e199f789c5173535

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
	&& apt-get install -y --no-install-recommends -o APT::Architecture-Variants="" libsqlite3-0 \
	&& lib=/usr/lib/$(uname -m)-linux-gnu/libsqlite3.so.0 \
	&& test -e "$lib" \
	&& test -e /usr/lib/jellyfin/bin/libe_sqlite3.so \
	&& ln -sf "$lib" /usr/lib/jellyfin/bin/libe_sqlite3.so \
	&& rm -rf /var/lib/apt/lists/*
