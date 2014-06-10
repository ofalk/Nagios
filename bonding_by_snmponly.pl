#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014

use strict;
use warnings;

# Modules
use Net::SNMP;
use Getopt::Long;

# Constants
use constant BASE => '.1.3.6.1.2.1.2.2.1.';
use constant TABLES => {
	DESC	=> BASE . '2',
	MAC	=> BASE . '6',
#	ADMIN	=> BASE . '7',
	OPER	=> BASE . '8',
};
use constant ERRORS => {
	'OK'		=> 0,
	'WARNING'	=> 1,
	'CRITICAL'	=> 2,
	'UNKNOWN'	=> 3,
};

# Default values for our options / variable definition
my $timeout = 15;
my $community = 'public';
my $hostname;
my $port = 161;
my $missingok = 0;
my $interface;
my $t;
my $status = 'OK';
my $debug = 0;

# Our exit subroutine... Just because it's handy
sub do_exit($) {
	# For debug...
	use Data::Dumper;
	warn Dumper($t) if $debug;
	# Watch out: Shift needs () here - else it's treated as hash key... 8-/
	exit ERRORS->{shift()};
}

# Setup and get options
# We do not support port names...
GetOptions(
	'H|hostname:s'		=> \$hostname,
	'C|community:s'		=> \$community,
	't|timeout:i'		=> \$timeout,
	'p|port:i'		=> \$port,
	'o|missingok'		=> \$missingok,
	'i|interface|int:s'	=> \$interface,
	'd|debug'		=> \$debug,
);

die 'No hostname given!' unless $hostname;

# Setup alarm and signal handler to get out even if something badly hangs
alarm($timeout);
$SIG{'ALRM'} = sub {
	print "Timeout: No answer from host\n";
	do_exit('UNKNOWN');
};

# We currently only support V1
my ($session, $error) = Net::SNMP->session(
	-hostname  => $hostname,
	-community => $community,
	-port      => $port,
	-timeout   => $timeout,
);

printf('ERROR opening session: %s.'."\n", $error) && do_exit('UNKNOWN') unless $session;

# Fetch all tables that we need to work with...
# Watch out: Use of constants abouve automagically created subroutines... 
# Watch out: Right hand notation here might confuse you, since it's multiline
$t->{$_} = $session->get_table(
	Baseoid => TABLES->{$_},
) foreach keys %{&TABLES};

# Now more even more right hand coding fun... Don't worry. This just works, no need to touch
# it ever again :-P
# Create by INT name
foreach my $k (keys %{$t->{DESC}}) {
	$k =~ m/.*\.(\d+)$/;
	$t->{by_int}->{$t->{DESC}->{$k}}->{$_} = $t->{$_}->{TABLES->{$_}.'.'.$1} foreach (keys %{&TABLES});
}
# Create by MAC
foreach (keys %{$t->{by_int}}) {
	# We ignore interfaces without MAC (usually lo)
	next unless $t->{by_int}->{$_}->{MAC};
	$t->{by_mac}->{$t->{by_int}->{$_}->{MAC}}->{$_} = $t->{by_int}->{$_};
}
# Now create it by bonding interface
foreach (keys %{$t->{by_mac}}) {
	my $master;
	my @slaves;
	while(scalar(keys %{$t->{by_mac}->{$_}}) > 0) {
		if ((keys %{$t->{by_mac}->{$_}})[0] =~ m/^bond/) {
			$master = (keys %{$t->{by_mac}->{$_}})[0];
		} else {
			push @slaves, (keys %{$t->{by_mac}->{$_}})[0];
		}
		delete $t->{by_mac}->{$_}->{(keys %{$t->{by_mac}->{$_}})[0]};
	}
	$t->{by_bond}->{$master} = \@slaves if $master;
}

# Interface specified on command line
if($interface) {
	if((!defined $t->{by_bond}->{$interface})) {
		if($missingok) {
			printf("OK: $interface missing, but that is OK\n") && do_exit('OK');
		} else {
			printf("CRITICAL: $interface missing!\n") && do_exit('CRITICAL');
		}

		$t->{by_int}->{$interface}->{OPER} = 1 unless defined $t->{by_int}->{$interface}->{OPER};
		printf("CRITICAL: $interface is down\n") && do_exit('CRITICAL') if $t->{by_int}->{$interface}->{OPER} != 1;
	}
}

my $ok_msg = '';
my $warn_msg = '';
my $crit_msg = '';
foreach my $bond (keys %{$t->{by_bond}}) {
	next if ($interface && !($interface eq $bond));
	my $nok = 0;
	foreach(@{$t->{by_bond}->{$bond}}) {
		$t->{by_int}->{$_}->{OPER} = 1 unless defined $t->{by_int}->{$_}->{OPER};
		$nok++ if $t->{by_int}->{$_}->{OPER} != 1;
	}
	if($nok >= scalar @{$t->{by_bond}->{$bond}}) {
		$status = 'CRITICAL';
		$crit_msg .= sprintf("CRITICAL: All slave interfaces for $bond are down!\n");
	} elsif($nok >= 1) {
		$status = 'WARNING' if $status ne 'CRITICAL';
		$warn_msg .= sprintf("WARNING: $nok slave interface(s) for $bond are down!\n");
	} elsif(scalar @{$t->{by_bond}->{$bond}} < 2) {
		$status = 'WARNING' if $status ne 'CRITICAL';
		$warn_msg .= sprintf("WARNING: $bond has only 1 active interface!\n");
	} else {
		$ok_msg .= sprintf("OK: All slave interfaces for $bond are up!\n");
	}
}

print "$crit_msg\n" if $crit_msg;
print "$warn_msg\n" if $warn_msg;
print "$ok_msg" if $ok_msg;
do_exit($status);
