#!/bin/sh

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013

LDAPSEARCH=/usr/bin/ldapsearch

if [ $# -lt 3 ]; then
	echo "Not enough arguments; Use $0 <host1> <host2> <basedn>"
	exit -255
fi

HOST1=$1
HOST2=$2
BASEDN=$3

NOHOST1=$($LDAPSEARCH -x -h $HOST1 -b "$BASEDN" | grep numResponses | awk '{ print $3 }')
NOHOST2=$($LDAPSEARCH -x -h $HOST2 -b "$BASEDN" | grep numResponses | awk '{ print $3 }')

msg="$HOST1 = $NOHOST1, $HOST2 = $NOHOST2"
perfdata="$HOST1=$NOHOST1 $HOST2=$NOHOST2"

if [ "$NOHOST1" != "$NOHOST2" ]; then
	echo "CRITICAL: $msg | $perfdata"
	exit 2
else
	echo "OK: $msg | $perfdata"
	exit 0
fi
