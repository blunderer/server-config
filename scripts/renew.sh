#!/bin/bash

set -x

DATA="/home/new-data/keys/"
export PATH=$PATH:/home/blunderer/Projects/getssl

# Renew if required
getssl -w $DATA/ssl blunderer.org

PRV_KEY=$DATA/ssl/blunderer.org/blunderer.org.key
CERT=$DATA/ssl/blunderer.org/blunderer.org.crt
FULLCHAIN=$DATA/ssl/blunderer.org/fullchain.crt
LIGHTTPD_CERT=$DATA/ssl/blunderer.org/all.pem
CA_CERT=$DATA/ssl/blunderer.org/ca.pem

# Prepare lighttpd SSL cert: concatenation of key and cert
cat $PRV_KEY $CERT > $LIGHTTPD_CERT

# Deploy to local and all remotes.
DEST="$DATA backup.blunderer.org:$DATA"
for dest in $DEST; do
  # main keys
  if [ "$dest" != "$DATA" ]; then
	  rsync -aP $DATA/ssl/ $dest/ssl/
  fi

  # Deploy postfix SSL
  rsync -aP $PRV_KEY $dest/postfix/ssl/private/blunderer.org.key
  rsync -aP $CERT $dest/postfix/ssl/certs/blunderer.org.crt
  
  # Deploy lighttpd SSL
  rsync -aP $LIGHTTPD_CERT $dest/lighttpd/server.pem
  rsync -aP $CA_CERT $dest/lighttpd/ca.pem
done
