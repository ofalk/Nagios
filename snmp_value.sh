#!/bin/sh

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014
# Simply fetch exactly 1 value

if [ -z $3 ]; then
	echo "Usage: $0 <community> <hostname> <oid> <uom>"
	exit -1
fi

uom=""
if [ ! -z $4 ]; then
	uom=$4
fi

val=`/usr/bin/snmpget -v1 -c $1 -OvU $2 $3 | cut -f 2 -d " "`
if [ -z $val ]; then
	echo "Error: No value"
	exit 3
fi

echo "OK value=$val|value=$val$uom;;;;"

exit 0
