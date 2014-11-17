#!/bin/sh

# Small and simple script that fetches a file from a Windows
# server and compares it to the file previously fetched.
# Raise an error if there are differences.
# To get rid of the error, remove the "cached" file from /tmp

if [ -z $4 ]; then
	echo "Usage: $0 <hostname> </share/file> <user> <password>"
	exit -1
fi
HOSTNAME=$1
# From wherever we get this $ at the end :-/
FILE=`echo "$2"|sed -e 's^$$^^'`
echo $FILE
USER=$3
PASS=$4
TMP_FILENAME="/tmp/$HOSTNAME"_"`echo $FILE|sed -e 's/\//_/g'`"
TMP_SAVE_FILENAME="$TMP_FILENAME.save"

if [ -f $TMP_FILENAME ]; then
	rm $TMP_FILENAME
fi
path="smb://$HOSTNAME/$FILE"

smbget $path -q -u "$USER" -p "$PASS" -o $TMP_FILENAME 

if [ ! -f $TMP_FILENAME ]; then
	echo "UNKNOWN: Cannot download file: '$path' !?"
	exit 4
fi

if [ ! -f $TMP_SAVE_FILENAME ]; then
	mv -f $TMP_FILENAME $TMP_SAVE_FILENAME
	echo "OK: New file"
	exit 0
else 
	diff="`diff $TMP_SAVE_FILENAME $TMP_FILENAME`"
	rm $TMP_FILENAME
	if [ "$diff" == "" ]; then
		echo "OK: No changes found"
		exit 0
	else
		echo "ERROR: Changes found:"
		echo "$diff"
		exit 2
	fi
fi
