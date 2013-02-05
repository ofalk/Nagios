#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013
# Use this script to make sure hanging SNMP queries will be killed

use strict;
use warnings;
use File::Basename;
my $dirname = dirname(__FILE__);

use constant TIMEOUT => 80;

$SIG{'ALRM'} = sub {
	print "UNKNOWN: Timeout: No answer from host - ignoring\n";
	exit 3;
};
alarm(TIMEOUT);

# Make sure we don't pass any special characters without
# quoting them (eg '(', ')', or '|').
my @argv;
push @argv, "'$_'" foreach @ARGV;

exec(dirname(__FILE__) . "/check_snmp_process " . join(" ", @argv));
