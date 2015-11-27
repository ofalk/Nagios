#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2015
# Use this script to make sure hanging SNMP queries will be killed

use strict;
use warnings;
use File::Basename;
use Proc::ProcessTable;
my $dirname = dirname(__FILE__);
my $retval = 0;

use constant TIMEOUT => 200;

# Make sure we kill the forked process as soon as we exit
END {
	my $t = Proc::ProcessTable->new();
	my @proc_kids = map { $_->pid() }
					grep { $_->ppid() == $$ }
					@{$t->table()};
	foreach(@proc_kids) {
		# warn "Need to kill $_"; # Debug only
		kill 15, $_;
	}
}

$SIG{'ALRM'} = sub {
	print "UNKNOWN: Timeout: No answer from host - ignoring\n";
	exit 3;
};
alarm(TIMEOUT);

# Make sure we don't pass any special characters without
# quoting them (eg '(', ')', or '|').
my @argv;
push @argv, "'$_'" foreach @ARGV;

setpgrp $$, 0;
system(dirname(__FILE__) . "/check_snmp_process " . join(" ", @argv));
$retval = $? >> 8;
exit $retval;
