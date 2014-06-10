#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014
# 
# This script could use some love... Especially caching would be a _very_
# good idea. Eg. based on my 'check_snmp_dskusg' script...

# Use it with EMC² Symmetrix storages

use strict;
use warnings;

use Getopt::Long;
use XML::Simple;
use Data::Dumper; # Only during DEV
use feature qw/switch/;

$ENV{SYMCLI_CONNECT_TYPE} = 'REMOTE';

use constant SYMHOME => '/opt/emc/SYMCLI/bin/';

use constant ERRORS => {
	'OK'		=> 0,
	'WARNING'	=> 1,
	'CRITICAL'	=> 2,
	'UNKNOWN'	=> 3,
};

# Our exit subroutine... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	warn $mesg if $mesg;
	exit ERRORS->{$code};
}

my ($sid, $debug, $site, $check);
my $totals = 0;

sub debug_log($) {
	my $line = shift;
	print "DEBUG: " . $line . "\n" if $debug;
}

my $result = GetOptions(
	"sid|s=s"	=> \$sid,
	"site=s"	=> \$site,
	"check|c=s"	=> \$check,
	"totals|t"	=> \$totals,
	"debug|d"	=> \$debug,
);

do_exit('CRITICAL', "No SID given (or evaluates to false)") unless $sid;
do_exit('CRITICAL', "No site given") unless $site;
do_exit('CRITICAL', "No check") unless $check;

given($check) {
	when('rw_cache_hit_pct') 	{ break }
	when('r_per_second')		{ break }
	when('io_per_second')		{ break }
	when('rw_per_second')		{ break }
	when('w_per_second')		{ break }
	default				{ do_exit('CRITICAL', "Check: '$check' doesn't exist") }
}

$ENV{SYMCLI_CONNECT} = $site;

my $output = '';
my $interval = 5;
my $command = SYMHOME . "symstat -sid $sid -i $interval -c 1 -dir all -output XML";

debug_log("Command: $command");
open(CMD, $command . '|');
while(<CMD>) {
	$output .= $_;
	chomp; debug_log("Output: $_");
}
close(CMD);

do_exit('ERROR', "No valid output from command: $command") unless $output;

my $ref = XMLin(\$output);

#die Dumper($ref);

if($ref->{Statistics}) {
	my $perfdata = "";
	my $out = "";
	foreach (@{$ref->{Statistics}}) {
		next unless $_->{Dir_Request_Totals};

		unless($totals) {
			foreach my $dir (@{$_->{Dir_Request}}) {
				# Special handlings for special cases
				next if (($check eq 'r_per_second') && ($dir->{director} =~ /^RF-/));
				next if (($check eq 'rw_cache_hit_pct') && ($dir->{director} =~ /^RF-/));
				next if (($check eq 'rw_cache_hit_pct') && ($dir->{director} =~ /^DF-/));

				$out .= "$dir->{director}";
				$out .= " R/W Cache Hit: $dir->{'rw_cache_hit_pct'}\n"				if $check eq 'rw_cache_hit_pct';
				$out .= " R/Second:      $dir->{'r_per_second'}\n"				if $check eq 'r_per_second';
				$out .= " IO/Second:     $dir->{'io_per_second'}\n"				if $check eq 'io_per_second';
				$out .= " R/W/Second:    $dir->{'rw_per_second'}\n"				if $check eq 'rw_per_second';
				$out .= " W/Second:      $dir->{'w_per_second'}\n"				if $check eq 'w_per_second';

				$perfdata .= "$dir->{director}_rw_cache_hit_pct=$dir->{'rw_cache_hit_pct'};;;;"	if $check eq 'rw_cache_hit_pct';
				$perfdata .= "$dir->{director}_r_per_second=$dir->{'r_per_second'};;;;"		if $check eq 'r_per_second';
				$perfdata .= "$dir->{director}_io_per_second=$dir->{'io_per_second'};;;;"	if $check eq 'io_per_second';
				$perfdata .= "$dir->{director}_rw_per_second=$dir->{'rw_per_second'};;;;"	if $check eq 'rw_per_second';
				$perfdata .= "$dir->{director}_w_per_second=$dir->{'w_per_second'};;;;"		if $check eq 'w_per_second';
			}
		} else {
			$out .= "Total R/W Cache Hit: $_->{Dir_Request_Totals}->{'rw_cache_hit_pct'}\n"			if $check eq 'rw_cache_hit_pct';
			$out .= "Total R/Second:      $_->{Dir_Request_Totals}->{'r_per_second'}\n"			if $check eq 'r_per_second';
			$out .= "Total IO/Second:     $_->{Dir_Request_Totals}->{'io_per_second'}\n"			if $check eq 'io_per_second';
			$out .= "Total R/W/Second:    $_->{Dir_Request_Totals}->{'rw_per_second'}\n"			if $check eq 'rw_per_second';
			$out .= "Total W/Second:      $_->{Dir_Request_Totals}->{'w_per_second'}\n"			if $check eq 'w_per_second';

			$perfdata .= "total_rw_cache_hit_pct=$_->{Dir_Request_Totals}->{'rw_cache_hit_pct'};;;;"	if $check eq 'rw_cache_hit_pct';
			$perfdata .= "total_r_per_second=$_->{Dir_Request_Totals}->{'r_per_second'};;;;"		if $check eq 'r_per_second';
			$perfdata .= "total_io_per_second=$_->{Dir_Request_Totals}->{'io_per_second'};;;;"		if $check eq 'io_per_second';
			$perfdata .= "total_rw_per_second=$_->{Dir_Request_Totals}->{'rw_per_second'};;;;"		if $check eq 'rw_per_second';
			$perfdata .= "total_w_per_second=$_->{Dir_Request_Totals}->{'w_per_second'};;;;"		if $check eq 'w_per_second';
		}
	}
	print "OK\n$out | $perfdata\n";
} else {
	do_exit('ERROR', "No valid output from command: $command");
}

# use this only during development
# use Data::Dumper;
# print Dumper($ref);

do_exit('OK');
