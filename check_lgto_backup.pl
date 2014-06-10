#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014

use strict;
use warnings;

use lib qw(/opt/omd/sites/test/etc/nagios/conf.d/hosts/unix-linux/);
use SITE qw/$SITE/;

use Storable qw/lock_retrieve/;
use Carp qw/carp croak/;
use Getopt::Long;

use constant ERRORS => {
	'OK'		=> 0,
	'WARNING'	=> 1,
	'CRITICAL'	=> 2,
	'UNKNOWN'	=> 3,
};

my $hostname;
my $warn = 48 * 60 * 60;
my $crit = 60 * 60 * 60;
my $now = time();
my $site = $SITE;
my $result = GetOptions(
	"hostname|h=s"	=> \$hostname,
	"warn|w=i"	=> \$warn,
	"crit|c=i"	=> \$crit,
	"site|s=s"	=> \$site,
);

die "No hostname given" unless $hostname;
do_exit('CRITICAL', "No hostname given") unless $hostname;
do_exit('CRITICAL', "No site given") unless $site;

# Our exit subroutine... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	warn $mesg if $mesg;
	exit ERRORS->{$code};
}

my $saves;
unless($saves = lock_retrieve('/tmp/' . $site . '_mminfo.dat')) {
	croak("ERROR I/O problem while storing cachefile!");
}

my $bk;

if($saves->{$hostname}) {
	$bk = $saves->{$hostname};
} else {
	my $i = 0;
	foreach(keys %{$saves}) {
		if($_ =~ /^$hostname.*/) {
			$i++;
			warn "More than one possible hostname found!" if $i > 1;
			$bk = $saves->{$_};
		}
	}
}
use Data::Dumper;
#warn Dumper($bk);
do_exit('UNKNOWN', "UNKNOWN: No valid backup for $hostname found") unless $bk->{latest};
my $diff = $now - $bk->{latest};
do_exit('CRITICAL', "CRITICAL: Last backup for $hostname is $diff (> $crit) seconds ago") if $diff > $crit;
do_exit('WARNING', "WARNING: Last backup for $hostname is $diff (> $warn) seconds ago") if $diff > $warn;
do_exit('OK', "OK: Last backup for $hostname is $diff seconds ago");
