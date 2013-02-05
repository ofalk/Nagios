#!/usr/bin/perl -w

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013

use strict;
use warnings;
use Getopt::Long;
use Net::SNMP;

use constant ERRORS => {
	UNKNOWN		=> -1,
	OK		=> 0,
	WARNING		=> 1,
	CRITICAL	=> 2,
};

use constant TABLE => 'HOST-RESOURCES-MIB::hrSWRunStatus';

sub snmpwalkgrep {
	my ($hostname, $community, $tree, $text) = @_;
	my $walk = `snmpwalk -v 1 -c $community $hostname $tree |grep $text`;
	return $walk;
}

my ($hostname, $num_zombies);
my $warning = 1;
my $critical = 5;
my $community = 'public';

GetOptions(
	"hostname|h=s"	=> \$hostname,
	"community|c=s"	=> \$community,
	"warning|w=i"	=> \$warning,
	"error|e=i"	=> \$critical,
);

die "No hostname given!" unless $hostname;

my $inval = snmpwalkgrep($hostname, $community, TABLE, 'invalid');
if($inval) {
	my $i = 0;
	$i++ foreach (split(/\n/, $inval));
	if($i >= $critical) {
		print "CRITICAL: $i invalid processes found | invalid=$i;$warning;$critical\n";
		exit ERRORS->{CRITICAL};
	} elsif ($i >= $warning) {
		print "WARNING: $i invalid processes found | invalid=$i;$warning;$critical\n";
		exit ERRORS->{WARNING};
	} else {
		print "OK: $i invalid processes found | invalid=$i;$warning;$critical\n";
		exit ERRORS->{OK};
	}
}

print "OK: 0 invalid processes found | invalid=0;$warning;$critical\n";
exit ERRORS->{OK};

1;
