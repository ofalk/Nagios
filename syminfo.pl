#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014
# Fetch some basic infos about some EMC² Symmetrix storage

use strict;
use warnings;

use Getopt::Long;
use XML::Simple;

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

my ($sid, $debug, $site);

sub debug_log($) {
	my $line = shift;
	print "DEBUG: " . $line . "\n" if $debug;
}

my $result = GetOptions(
	"sid|s=s"	=> \$sid,
	"site=s"	=> \$site,
	"debug|d"	=> \$debug,
);

do_exit('CRITICAL', "No SID given (or evaluates to false)") unless $sid;
do_exit('CRITICAL', "No site given") unless $site;

$ENV{SYMCLI_CONNECT} = $site;

my $output = '';
my $command = SYMHOME . "symcfg -sid $sid -v list -dir all -output XML";
debug_log("Command: $command");
open(CMD, $command . '|');
while(<CMD>) {
	$output .= $_;
	chomp; debug_log("Output: $_");
}
close(CMD);

do_exit('ERROR', "No valid output from command: $command") unless $output;

my $ref = XMLin(\$output);

if($ref->{Symmetrix}) {
	my $sym = $ref->{Symmetrix};

	my $cache_device_wp_slots_max			= $sym->{Cache}->{'device_wp_slots_max'};
	my $cache_slots_available			= $sym->{Cache}->{'slots_available'};
	my $cache_system_wp_slots_max			= $sym->{Cache}->{'system_wp_slots_max'};
	my $cache_replication_cache_use_percent		= $sym->{Cache}->{'replication_cache_use_percent'};
	my $cache_da_wp_slots_max			= $sym->{Cache}->{'da_wp_slots_max'};
	my $cache_megabytes				= $sym->{Cache}->{'megabytes'} . 'MB';

	my $info_hot_spares				= $sym->{Symm_Info}->{'hot_spares'};
	my $info_devices				= $sym->{Symm_Info}->{'devices'};
	my $info_max_hypers_per_disk			= $sym->{Symm_Info}->{'max_hypers_per_disk'};
	my $info_disks					= $sym->{Symm_Info}->{'disks'};
	my $info_physical_devices			= $sym->{Symm_Info}->{'physical_devices'};
	my $info_unconfigured_disks			= $sym->{Symm_Info}->{'unconfigured_disks'};

	my $srdfa_max_cache_usage			= $sym->{SRDFA}->{'max_cache_usage'} . '%';
	my $srdfa_max_host_throttle			= $sym->{SRDFA}->{'max_host_throttle'};

	my $flags_symm_data_encryption			= $sym->{Flags}->{'symm_data_encryption'};
	my $flags_pav_mode				= $sym->{Flags}->{'pav_mode'};
	my $flags_cache_partition			= $sym->{Flags}->{'cache_partition'};

	$sym->{Times}->{'total_operating'} =~ m/(\d+)\ days.*/;
	my $uptime_days = $1 || 0;

	my $directors = $sym->{Director};
	my $num_dir = scalar @{$directors};

	# Plugin output
	print "OK\n";
	print "Cache:\n";
	print "   - Device WP Slots MAX:     $cache_device_wp_slots_max\n";
	print "   - Slots Available:         $cache_slots_available\n";
	print "   - System WP Slots MAX:     $cache_system_wp_slots_max\n";
	print "   - Replication Cache use %: $cache_replication_cache_use_percent\n";
	print "   - DA WP Slots MAX:         $cache_da_wp_slots_max\n";
	print "   - Memory:                  $cache_megabytes\n";
	print "Info:\n";
	print "   - Hot spares:              $info_hot_spares\n";
	print "   - Devices:                 $info_devices\n";
	print "   - Max Hypers/Disk:         $info_max_hypers_per_disk\n";
	print "   - Disks:                   $info_disks\n";
	print "   - Physical Devices:        $info_physical_devices\n";
	print "   - Unconfigured Disks:      $info_unconfigured_disks\n";
	print "   - Directors:               $num_dir\n";
	print "Times:\n";
	print "   - Uptime:                  $uptime_days days\n";
	print "Flags:\n";
	print "   - Encryption:              $flags_symm_data_encryption\n";
	print "   - PAV Mode:                $flags_pav_mode\n";
	print "   - Cache Partition:         $flags_cache_partition\n";
	print "SRDFA:\n";
	print "   - MAX Cache Usage:         $srdfa_max_cache_usage\n";
	print "   - MAX Host Throttle:       $srdfa_max_host_throttle\n";
	print "Directors:\n";
	foreach my $dir (@{$directors}) {
		print "   - " . $dir->{Dir_Info}->{symbolic} . "\n";
		# TODO Check: Should be checked to be >= 4!!
		print "      +  Speed:  " . $dir->{Dir_Info}->{'negotiated_speed'} . "\n" if $dir->{Dir_Info}->{'negotiated_speed'};
		# TODO Check: Should be equal 'Online'
		print "      +  Status: " . $dir->{Dir_Info}->{'status'}           . "\n";
		print "      +  Type:   " . $dir->{Dir_Info}->{'type'}             . "\n";
		print "      +  ID:     " . $dir->{Dir_Info}->{'id'}               . "\n";
		print "      +  Slot:   " . $dir->{Dir_Info}->{'slot'}             . "\n";
	}

	# Perfdata
	print "| cache_device_wp_slots_max=$cache_device_wp_slots_max;;;; cache_slots_available=$cache_slots_available;;;; cache_system_wp_slots_max=$cache_system_wp_slots_max;;;; cache_replication_cache_use_percent=$cache_replication_cache_use_percent;;;; cache_da_wp_slots_max=$cache_da_wp_slots_max;;;; cache_megabytes=$cache_megabytes;;;; info_hot_spares=$info_hot_spares;1;0;; info_devices=$info_devices;;;; info_max_hypers_per_disk=$info_max_hypers_per_disk;;;; info_disks=$info_disks;;;; info_physical_devices=$info_physical_devices;;;; info_unconfigured_disks=$info_unconfigured_disks;;;; srdfa_max_cache_usage=$srdfa_max_cache_usage;;;; srdfa_max_host_throttle=$srdfa_max_host_throttle;;;; directors=$num_dir;;;; uptime=$uptime_days";
} else {
	do_exit('ERROR', "No valid output from command: $command");
}

# use this only during development
# use Data::Dumper;
# print Dumper($ref);

do_exit('OK');
