#!/bin/sh

N_USER=$1
N_GROUP=$2
N_UID=$3
N_GID=$4

# Retrieve old uid/gid
eval $(grep "$N_USER" /etc/passwd | tr ":" " " | awk '{print "O_UID="$3 "; O_GID=" $4}')

# Update user
sed -i "s/^$N_USER:x:\(.*\):\(.*\)\(:.*:.*:.*\)$/$N_USER:x:$N_UID:$N_GID\3/" /etc/passwd
sed -i "s/^$N_GROUP:x:\(.*\):\(.*\)$/$N_GROUP:x:$N_GID:\2/" /etc/group

# Update all files permissions
chown --from=$O_UID:$O_GID -R $N_USER:$N_GROUP / 2> /dev/null || true
chown --from=$O_UID -R $N_USER / 2> /dev/null || true
