#!/bin/bash

# Renew if required
getssh -w /home/data/keys/ssl blunderer.org

PRV_KEY=/home/data/keys/ssl/blunderer.org.key
CERT=/home/data/keys/ssl/blunderer.org.crt
FULLCHAIN=/home/data/keys/ssl/blunderer.org/fullchain.crt
LIGHTTPD_CERT=/home/data/keys/ssl/blunderer.org/all.pem
CA_CERT=/home/data/keys/ssl/blunderer.org/ca.pem

# Prepare lighttpd SSL cert: concatenation of key and cert
cat $PRV_KEY $CERT > $LIGHTTPD_CERT

# Deploy to local and all remotes.
DEST="/home/data/keys backup.blunderer.org:/home/data/keys"
for dest in $DEST; do
  # Deploy postfix SSL
  rsync $PRV_KEY $dest/postfix/ssl/private/blunderer.org.key
  rsync $CERT $dest/postfix/ssl/certs/blunderer.org.crt
  
  # Deploy lighttpd SSL
  rsync $LIGHTTPD_CERT $dest/lighttpd/server.pem
  rsync $CA_CERT $dest/lighttpd/ca.pem
done
