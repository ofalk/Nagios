#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013

use strict;
use warnings;

## setup phase

use Getopt::Long;
use Net::SNMP;
use Data::Dumper; # TODO - remove this after development

use constant BASEOID => '1.3.6.1.4.1.1714.1';
use constant DEVICES => BASEOID . '.1.9.1.8';
use constant DEVICE_VALUES => BASEOID . '.1.9.1.9';
use constant DEVICE_STATUS => BASEOID . '.1.9.1.13';

use constant PARTITIONS => BASEOID . '.1.4.1.2';

use constant UPTIME => '1.3.6.1.2.1.1.3.0';
use constant VENDOR => BASEOID . '.1.1.1.14.0';
use constant MODEL => BASEOID . '.1.1.1.13.0';
use constant SERIAL => BASEOID . '.1.1.1.10.0';
use constant FW_MAJOR => BASEOID . '.1.1.1.4.0';
use constant FW_MINOR => BASEOID . '.1.1.1.5.0';

use constant LD => BASEOID . '.1.2';
use constant LD_TOTAL_DRIVE_COUNT => BASEOID . '.1.2.1.8';
use constant LD_SPARE_DRIVE_COUNT => BASEOID . '.1.2.1.10';
use constant LD_FAILED_DRIVE_COUNT => BASEOID . '.1.2.1.11';
use constant LD_STATUS => BASEOID . '.1.2.1.6';
use constant HD_STATUS  => BASEOID . '.1.6.1.11';

# NAGIOS constants
use constant UNKNOWN => 3;
use constant CRITICAL => 2;
use constant WARNING => 1;
use constant OK => 0;

use constant SNMP_VERSION => 1;

my $overall_status = OK;
my $overall_msg = "";

# Initialize options
my $community = 'public';
my $hostname;
my $debug = 0;
my $ignore_ups = 1;

my $result = GetOptions(
	"community|c=s"		=> \$community,
	"debug|d"		=> \$debug,
	"hostname|h=s"		=> \$hostname,
	"ignore_ups"		=> \$ignore_ups,
);

my ($device, $ld, $volts, $temps, $fans);

exit -255 unless $result;
unless($hostname) {
	die "Sorry, no hostname given";
}
warn "hostname: $hostname, $community: $community" if $debug;

## connection initialisation phase

my ($session, $error) = Net::SNMP->session(
	-hostname	=> $hostname,
	-community	=> $community,
	-version	=> SNMP_VERSION,
	-debug		=> $debug,
);

die "Session unsuccessful: $error" unless defined($session);

## data gathering phase

sub _get_simple_value($$) {
	my $session = shift;
	my $oid = shift;
	my $values = $session->get_request(
		-varbindlist	=> [ $oid ],
	);
	if($session->error) {
		# Net::SNMP will error out anyway - no need to explicit add an error message
		exit UNKNOWN;
	}

	foreach(keys %{$values}) {
		# use the first and return - simple value we said
		return $values->{$_};
	}
}

my $uptime = _get_simple_value($session, UPTIME);
warn "Uptime: $uptime" if $debug;

my $vendor = _get_simple_value($session, VENDOR);
warn "Vendor: $vendor" if $debug;

my $model = _get_simple_value($session, MODEL);
warn "Model: $model" if $debug;

my $serial = _get_simple_value($session, SERIAL);
warn "Serial: $serial" if $debug;

my $fw_major = _get_simple_value($session, FW_MAJOR);
my $fw_minor = _get_simple_value($session, FW_MINOR);
my $firmware = "$fw_major.$fw_minor";
warn "FW: $firmware" if $debug;

sub _return_oid_table($$) {
	my $session = shift;
	my $oid = shift;
	return $session->get_table(
		-baseoid	=> $oid,
	);
}

my $partition_count = keys %{_return_oid_table($session, PARTITIONS)};
warn "Partition Count: $partition_count" if $debug;

sub _fetch_and_parse_devices($$$) {
	my $session = shift;
	my $oid = shift;
	my $name = shift;
	my $table = _return_oid_table($session, $oid);
	foreach(keys %{$table}) {
		my $h = $_;
		$h =~ s/$oid\.//;
		$device->{$h}->{$name} = $table->{$_};
	}
}

_fetch_and_parse_devices($session, DEVICES, 'description');
_fetch_and_parse_devices($session, DEVICE_VALUES, 'value');
_fetch_and_parse_devices($session, DEVICE_STATUS, 'status');

sub _fetch_and_parse_ld($$) {
	my $session = shift;
	my $oid = shift;
	my $table = _return_oid_table($session, $oid);
	foreach(keys %{$table}) {
		my $h = $_;
		$h =~ s/$oid\.//;
		$h =~ m/^(\d+)\.(\d+)\.1$/;
		my $i = $1;
		my $uid = $table->{"$oid.$i.2.1"};
		next if $ld->{$uid}; # to avoid doing it serveral times...
		$ld->{$uid}->{drive_count} = $table->{"$oid.$i.8.1"};
		$ld->{$uid}->{online_drives} = $table->{"$oid.$i.9.1"};
		$ld->{$uid}->{ld_state} = $table->{"$oid.$i.7.1"};
		$ld->{$uid}->{ld_status} = $table->{"$oid.$i.6.1"};
		$ld->{$uid}->{ld_opmodes} = $table->{"$oid.$i.5.1"};
		$ld->{$uid}->{ld_blksizeidx} = $table->{"$oid.$i.4.1"};
		{
			no warnings; # at least on 32 bit systems, the next line would result in a warning
			$ld->{$uid}->{ld_size} = hex($table->{"$oid.$i.3.1"}) / 2 / 1024; # why do we need this? 
		}
		$ld->{$uid}->{ld_failed_drive_count} = $table->{"$oid.$i.11.1"};
		$ld->{$uid}->{ld_spare_drive_count} = $table->{"$oid.$i.10.1"};
	}
	
}

_fetch_and_parse_ld($session, LD);

# warn Dumper($ld);

## parsing phase (data jugling / data preparation)

my $ld_count = 0;
my $drive_count = 0;
my $failed_drive_count = 0;
my $online_drives = 0;
foreach(keys %{$ld}) {
	$ld->{$_}->{nagios_status} = OK;
	$ld->{$_}->{nagios_status} = CRITICAL unless $ld->{$_}->{ld_state} eq 0;
	$ld->{$_}->{nagios_status} = CRITICAL unless $ld->{$_}->{ld_status} eq 0;
	$ld->{$_}->{nagios_status} = CRITICAL unless $ld->{$_}->{drive_count} eq $ld->{$_}->{online_drives};
	$drive_count += $ld->{$_}->{drive_count};
	$online_drives += $ld->{$_}->{online_drives};
	$ld->{$_}->{nagios_status} = CRITICAL unless $ld->{$_}->{ld_failed_drive_count} eq 0;
	$failed_drive_count += $ld->{$_}->{ld_failed_drive_count};
	$overall_status = $ld->{$_}->{nagios_status} unless $overall_status != OK;
	$ld_count++;
}

foreach(keys %{$device}) {
	if(($device->{$_}->{description} =~ m/^UPS/) && $ignore_ups) {
		delete $device->{$_};
		next;
	}
	if($device->{$_}->{description}) {
		$device->{$device->{$_}->{description}} = {
			status	=> $device->{$_}->{status},
			value	=> $device->{$_}->{value},
		};
		if($device->{$_}->{status} != 0) {
			# Ignore the Attention LED - if there's some real problem
			# there will be a real error...
			next if $device->{$_}->{description} eq "Attention LED";
			$overall_status = CRITICAL;
			$overall_msg .= $device->{$_}->{description} . " not OK; ";
		}

		if($device->{$_}->{description} =~ m/^PSU.*V$/) {
			$volts->{$device->{$_}->{description}} = $device->{$_}->{value} / 1000;
		}
		if($device->{$_}->{description} =~ m/Temperature/) {
			$temps->{$device->{$_}->{description}} = $device->{$_}->{value} / 10;
		}
		if($device->{$_}->{description} =~ m/^Cooling fan/) {
			$fans->{$device->{$_}->{description}} = $device->{$_}->{value};
		}

	}
	delete $device->{$_};
}

$session->close();

#warn Dumper($volts);
#warn Dumper($temps);
#warn Dumper($fans);

## data output phase
# OK: Vendor:IFT  Model:A24F-G2430  Serial Number: 7412010  Firmware Version:3.73  Logical Drives:23  Spare Drives:1  Failed Drives:0 | 'CPU Temperature'=-274;70;80;0;100 'Controller Temperature(1)'=-274;70;80;0;100 'Controller Temperature(2)'=-274;70;80;0;100 'Cooling fan0'=0;6000;7000;0;8000 'Cooling fan1'=0;6000;7000;0;8000 'Cooling fan2'=0;6000;7000;0;8000 'Cooling fan3'=0;6000;7000;0;8000 'Backplane Temperature'=-274;70;80;0;100 

print "UNKNOWN: "			if $overall_status eq UNKNOWN;
print "CRITICAL: $overall_msg: "	if $overall_status eq CRITICAL;
print "WARNING: $overall_msg: "		if $overall_status eq WARNING;
print "OK: "				if $overall_status eq OK;
print "Vendor: $vendor  Model: $model  Serial Number: $serial  Firmware: $firmware  Partitions: $partition_count  Logical drives: $ld_count  ";
print "Online drives: $online_drives  Drives: $drive_count  Failed drives: $failed_drive_count  ";
print " | ";
## data output phase - performance data
print "'Partitions'=$partition_count;;;; 'Logical drives'=$ld_count;;;; ";
print "'Online drives'=$online_drives;;;; 'Drives'=$drive_count;;;; 'Failed drives'=$failed_drive_count;;;; ";
print "'$_'=" . $volts->{$_} . ';;;; ' foreach keys %{$volts};
print "'$_'=" . $temps->{$_} . ';;;; ' foreach keys %{$temps};
print "'$_'=" . $fans->{$_} . ';;;; ' foreach keys %{$fans};


print "\n";
warn $overall_msg if $overall_msg;


exit $overall_status;
