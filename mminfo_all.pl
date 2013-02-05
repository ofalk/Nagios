#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013
# Use this together with check_lgto_backup.pl
# Initially written for OMV/Petrom

use strict;
use warnings;

use lib qw(/opt/omd/sites/test/etc/nagios/conf.d/hosts/unix-linux/);
# A very small module that just exports $SITE to define if we
# are running in Austria or Romania
# You can also set it as my $SITE = 'mysite'
use SITE qw/$SITE/;

use Storable qw/lock_store lock_retrieve/;
use Carp qw/carp croak/;

# See above note. We need to put this into some config file
# and write some documentation. But for now... It's OK.
use constant HOSTS	=> {
	Austria => [ qw(lgtoatsrv1 lgtoatsrv2) ],
	Romania => [ qw(lgtorosrv1 lgtorosrv2) ],
};

use constant COMMAND	=> "mminfo -a -q 'sscreate>=3 days ago' -r 'volume,client,name,level,totalsize,nsavetime,sscreate(25),ssretent(25),pool' -xc';' -s";

my $saves = {};

foreach my $host (@{HOSTS->{$SITE}}) {
	print "Querying $host\n";
	open(FH, COMMAND . " $host |");
	while(<FH>) {
		next if /^volume;/;
		chomp();
		# volume;client;name;level;total;savetime;ss-created;retention-time;pool
		# VS0426;wmnfs.at.omv.com;/wmdata;full;33514039388;1359316440;01/27/2013 08:54:25 PM;03/03/2013 11:59:59 PM;2flocp1tape5w
		my ($volume, $client, $name, $level, $total, $savetime, $sscreated, $retention, $pool) = split(/;/);

		$client =~ s/.ww.omv.com$//;
		$client =~ s/.at.omv.com$//;

		$saves->{$client}->{$name} = {
			volume		=> $volume,
			level		=> $level,
			total		=> $total,
			savetime	=> $savetime,
			sscreated	=> $sscreated,
			retention	=> $retention,
			pool		=> $pool,
		};
		$saves->{$client}->{latest} = $savetime unless $saves->{$client}->{latest};
		$saves->{$client}->{latest} = $savetime if $savetime > $saves->{$client}->{latest};
	}
	close(FH);
}
unless(lock_store($saves, '/tmp/' . $SITE . '_mminfo.dat')) {
	croak("ERROR I/O problem while storing cachefile!");
}

use Data::Dumper;
