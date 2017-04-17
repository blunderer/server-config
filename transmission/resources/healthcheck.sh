#!/bin/bash

wget localhost:9091 -O /dev/null
[ $? -eq 6 ] 
