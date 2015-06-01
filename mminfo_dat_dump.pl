#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014
# Use this script to debug problems with mminfo, check_lgto_backup.pl

use strict;
use warnings;

use lib qw(/opt/omd/sites/test/etc/nagios/conf.d/hosts/unix-linux/);
use SITE qw/$SITE/;
my $site = $SITE;

use Data::Dumper;
use Storable qw/lock_retrieve/;

my $saves;

unless($saves = lock_retrieve('/tmp/' . $site . '_mminfo.dat')) {
	croak("ERROR I/O problem while storing cachefile!");
}

if($ARGV[0]){
	print Dumper($saves->{$ARGV[0]});
} else {
	print Dumper($saves);
}
