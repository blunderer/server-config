#!/bin/sh

. /env

torsocks wget -O /dev/null http://${onion_name}.onion/
return $?
