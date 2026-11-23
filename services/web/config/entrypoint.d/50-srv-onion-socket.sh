#!/bin/sh
# Remove a socket left by a previous container, or nginx cannot bind it.
rm -f /run/onion/web.sock
