#!/bin/sh
# Apply the canonical Jellyfin configuration from /etc/srv/jellyfin before
# handing off to linuxserver's /init.
#
# network.xml holds only deployment topology (ports, reverse-proxy subnets)
# and is replaced wholesale on every start. system.xml and encoding.xml also
# hold runtime/UI state, so they are seeded from the templates on first boot
# and patched in place afterwards.
set -eu

mkdir -p /config
cp /etc/srv/jellyfin/network.xml /config/network.xml

# set_xml_tag FILE ROOT_TAG TAG VALUE: enforce <TAG>VALUE</TAG> in place.
set_xml_tag() {
	file=$1 root=$2 tag=$3 val=$4
	awk -v root="$root" -v tag="$tag" -v val="$val" '
		$0 ~ "<" tag ">[^<]*</" tag ">" {
			sub("<" tag ">[^<]*</" tag ">", "<" tag ">" val "</" tag ">")
			done = 1
		}
		$0 ~ "<" tag "([ \t\r][^>]*)?/>" {
			sub("<" tag "([ \t\r][^>]*)?/>", "<" tag ">" val "</" tag ">")
			done = 1
		}
		$0 ~ "</" root ">" && !done {
			print "  <" tag ">" val "</" tag ">"
			done = 1
		}
		{ print }
	' "$file" >"$file.tmp"
	mv "$file.tmp" "$file"
}

if [ ! -s /config/system.xml ]; then
	cp /etc/srv/jellyfin/system.xml /config/system.xml
else
	set_xml_tag /config/system.xml ServerConfiguration EnableLegacyAuthorization true
fi

if [ ! -s /config/encoding.xml ]; then
	cp /etc/srv/jellyfin/encoding.xml /config/encoding.xml
else
	set_xml_tag /config/encoding.xml EncodingOptions EncoderPreset ultrafast
fi

chown "${PUID:-1000}:${PGID:-1000}" /config/network.xml /config/system.xml /config/encoding.xml
chmod 0644 /config/network.xml /config/system.xml /config/encoding.xml

exec /init "$@"
