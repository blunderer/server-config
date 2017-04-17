#!/bin/bash

mysql -u test 2>&1 | grep "Access denied for user 'test'"
