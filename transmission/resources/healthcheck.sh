#!/bin/bash

wget localhost:9091 -O /dev/null

EXITCODE=$?
if [ "$EXITCODE" -ne 6 ] ; then
        echo "Returned $EXITCODE"
        kill -15 1
        exit 1
fi

exit 0
