#!/bin/bash

echo "
q
exit
" | telnet -e q localhost 25

EXITCODE=$?
if [ "$EXITCODE" -ne 0 ] ; then
        echo "Returned $EXITCODE"
        kill -15 1
        exit 1
fi

exit 0
