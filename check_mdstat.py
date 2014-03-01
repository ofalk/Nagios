#!/usr/bin/python

# check_mdstat.py - plugin for nagios to check the status of linux swraid devices
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
# Copyright 2004 Duke University
# Written by Sean Dilda <sean@duke.edu>
# Small changes by Oliver Falk <oliver@linux-kernel.at>, 2012-2014

# Version: 0.2.1

import os
import sys
import string
import fileinput

mdFile = []
for line in fileinput.input():
    mdFile.append(line)

if(len(mdFile) < 5):
    print 'OK: No s/w raids defined'
    sys.exit(0)

# Remove the first, second, and lasts lines as we don't need them
mdFile.pop(0)
mdFile.pop()
mdFile.pop()

if ((len(mdFile)+1) % 3) != 0:
    print 'UNKNOWN: Error with mdstat file'
    sys.exit(3)

mdData = []
while len(mdFile) > 0:
    mdData.append((mdFile[0],mdFile[1]))
    mdFile = mdFile[3:]

overallStatus = 0
errorMsg = ''
for tup in mdData:
    device, colon, status, type, drives = string.split(tup[0], None, 4)
    drives = string.split(drives)
    values = string.split(tup[1])[-2]
    values = values[1:-1]
    try:
        normal, current = string.split(values, '/')
    except:
        continue
    normal = int(normal)
    current = int(current)


    # Status of 0 == Ok, 1 == Warning, 2 == Critical
    status = 0
    failed = 0
    degraded = 0
    msg = ''

    failed = []
    for drive in drives:
        if drive[-3:] == '(F)':
            failed.append(drive[:string.index(drive, '[')])
            status = 1
    failed = ' (' + string.join(failed, ', ') + ').'


    if status == 'inactive':
        status = 2
        msg = device + ' is inactive.'
    if type == 'raid5':
        if current < (normal -1):
            msg = device + ' failed' + failed 
            status = 2
        elif current < normal:
            msg = device + ' degraded' + failed
            status = 1
    else:
        if current < normal:
            msg = device + ' failed' + failed
            status = 2

    if len(msg) > 0:
        if len(errorMsg) > 0:
            errorMsg = errorMsg + '; '
        errorMsg = errorMsg + msg
        overallStatus = max(overallStatus, status)

if overallStatus == 0:
    print 'OK: All md devices Ok.'
    sys.exit(0)
else:
    print "ERROR: %s" % errorMsg
    sys.exit(overallStatus)
