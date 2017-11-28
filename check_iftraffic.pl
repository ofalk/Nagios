#!/usr/bin/perl -w
#
# check_iftraffic.pl - Nagios(r) network traffic monitor plugin
#
# Copyright (C) 2004 Gerd Mueller / Netways GmbH
# Copyright (C) 2006,2007,2009 Herbert Straub <herbert@linuxhacker.at>
# 
# 2007-01-09 Herbert Straub <herbert@linuxhacker.at>
# 	- correct Performance output with warn and critical (% and absolut)
# 2006-10-01 Herbert Straub <herbert@linuxhacker.at>
# 	- Overflow calculation error, because 2^^32 was wrong defined
#	- Option -d | --directory STRING -> new option, see --help
#	- Option -x -> new option for debugging purposes , see --help
#	- Do not die, if file could not be opened -> return UNKNOWN
#	- Implementing snmp v2
# 2011-01-22 Herbert Straub <herbert@linuxhacker.at>
#	- Implementing Bit/s, Option -o
#
# mw = Markus Werner mw+nagios@wobcom.de
# Remarks (mw):
#
#	I adopted as much as possible the programming style of the origin code.
#
#	There should be a function to exit this programm,
#	instead of calling print and exit statements all over the place.
#
# minor changes by mw
# 	The snmp if_counters on net devices can have overflows.
#	I wrote this code to address this situation.
#	It has no automatic detection and which point the overflow
#	occurs but it will generate a warning state and you
#	can set the max value by calling this script with an additional
#	arg.
#
# minor cosmetic changes by mw
#	Sorry but I couldn't sustain to clean up some things.
#
# based on check_traffic from Adrian Wieczorek, <ads (at) irc.pila.pl>
#
# Send us bug reports, questions and comments about this plugin.
# Latest version of this software: http://www.linuxhacker.at
#
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307

# requires:
#	perl-Crypt-DES-2.05-3.2.el5.rf.x86_64.rpm
#	perl-Net-SNMP-5.2.0-1.2.el5.rf.noarch.rpm

use strict;

use Net::SNMP;
use Getopt::Long;
&Getopt::Long::config('bundling');

use Data::Dumper;

my $host_address;
my $iface_number;
my $iface_descr;
my $iface_speed;
my ( $opt_h, $opt_license, $opt_version, $opt_output );
my $units;
my ( $snmpIfInOctets, $snmpIfOutOctets );
my $snmpIfDescr     = '1.3.6.1.2.1.2.2.1.2';
my $session;
my $error;
my $port         = 161;
my $snmp_version = 1;
my @snmpoids;
my $response;
my $version = "2.1";
my $output;

# Path to  tmp files
# FIXME: Straub: change to /var/lib/..., becaues data lost on tempfs filesystems!
my $DEF_DIR='/tmp';
my $TRAFFIC_FILE = "/traffic";
my ($directory, $traffic_file);
my $history_flag=0;

my %STATUS_CODE =
  ( 'UNKNOWN' => '-1', 'OK' => '0', 'WARNING' => '1', 'CRITICAL' => '2' );

#default values;
my ( $in_bytes, $out_bytes ) = 0;
my $warn_usage = 85;
my $crit_usage = 98;
my ($warn_abs, $crit_abs);
my $COMMUNITY  = "public";
my $max_value;
my $max_bytes;

my $status = GetOptions(
	"h|help"        => \$opt_h,
	"l|license"     => \$opt_license,
	"C|community=s" => \$COMMUNITY,
	"s|snmp_version=s"=> \$snmp_version,
	"w|warning=s"   => \$warn_usage,
	"c|critical=s"  => \$crit_usage,
	"b|bandwidth=i" => \$iface_speed,
	"p|port=i"      => \$port,
	"u|units=s"     => \$units,
	"i|interface=s" => \$iface_descr,
	"H|hostname=s"  => \$host_address,
	"M|max=i" => \$max_value,
	"d|directory=s" => \$directory,
	"x|history"	=> \$history_flag,
	"v|version"     => \$opt_version,
	"o|output=s"     => \$opt_output,
);

if ( $status == 0 ) {
	print_usage();
	exit $STATUS_CODE{'OK'};
}

if( $opt_license ) {
	print_license( );
	exit $STATUS_CODE{"OK"};
}

if( $opt_version ) {
	print_version( );
	exit $STATUS_CODE{"OK"};
}

if ( ( !$host_address ) or ( !$iface_descr ) or ( !$iface_speed ) ) {
	print_usage();
}

if ( ( $opt_output ) and
		( $opt_output ne "bits" and $opt_output ne "Bytes" )  ) {
	print "Error, you can only specify bits or Bytes for option -o\n";
	exit $STATUS_CODE{'UNKNOWN'};
}
	
if ( ! $opt_output ) {
	$opt_output = "Bytes";
}

# SNMP OIDs for Traffic
if ($snmp_version =~ /^1$/ ) { 
	$snmpIfInOctets  = '1.3.6.1.2.1.2.2.1.10';
	$snmpIfOutOctets = '1.3.6.1.2.1.2.2.1.16';
} elsif ($snmp_version =~ /^2c?$/) {
	$snmpIfInOctets  = '1.3.6.1.2.1.31.1.1.1.6';
	$snmpIfOutOctets = '1.3.6.1.2.1.31.1.1.1.10';
} else {
	print "Error - $snmp_version is currently not implemented!\n";
	return $STATUS_CODE{"UNKNOWN"};
}

if ( $snmp_version =~ /[12]/ ) {
	( $session, $error ) = Net::SNMP->session(
		-hostname  => $host_address,
		-community => $COMMUNITY,
		-port      => $port,
		-version   => $snmp_version
	);

	if ( !defined($session) ) {
		print("UNKNOWN: $error");
		exit $STATUS_CODE{'UNKNOWN'};
	}
}
elsif ( $snmp_version =~ /3/ ) {
	print("Error: No support for SNMP v3 yet\n");
	exit $STATUS_CODE{"UNKNOWN"};
}
else {
	print("Error: No support for SNMP v$snmp_version yet\n");
	exit $STATUS_CODE{"UNKNOWN"};
}

if ( $directory ) {
	$traffic_file=$directory.$TRAFFIC_FILE;
} else {
	$traffic_file=$DEF_DIR.$TRAFFIC_FILE;
}

$iface_speed = bits2bytes( $iface_speed, $units );
if ( !$max_value ) {
	#if no -M Parameter was set, set it to 32Bit Overflow
	$max_bytes = 4194304;    # the value is (2^32/1024)
}
else {
	$max_bytes = unit2bytes( $max_value, $units );
}

$iface_number = fetch_ifdescr( $session, $iface_descr );

push( @snmpoids, $snmpIfInOctets . "." . $iface_number );
push( @snmpoids, $snmpIfOutOctets . "." . $iface_number );

if ( !defined( $response = $session->get_request(@snmpoids) ) ) {
	my $answer = $session->error;
	$session->close;

	print("WARNING: SNMP error: $answer\n");
	exit $STATUS_CODE{'WARNING'};
}

$in_bytes  = $response->{ $snmpIfInOctets . "." . $iface_number };
$out_bytes = $response->{ $snmpIfOutOctets . "." . $iface_number };

$session->close;

my $row;
my $last_check_time = time - 1;
my $last_in_bytes   = $in_bytes;
my $last_out_bytes  = $out_bytes;

if ( open( FILE, "<" . $traffic_file . "_if" . $iface_number . "_" . $host_address)) {
	while ( $row = <FILE> ) {
		chomp($row);
		( $last_check_time, $last_in_bytes, $last_out_bytes ) =
		  split( ":", $row );
	}
	close(FILE);
}

my $update_time = time;

if (! open( FILE, ($history_flag ? ">>": ">") . $traffic_file . "_if" . $iface_number . "_" . $host_address )) {
	print "Error: Can't open $traffic_file for writing: $!\n";
	exit $STATUS_CODE{'UNKNOWN'};
}
printf FILE ( "%s:%.0f:%.0f\n", $update_time, $in_bytes, $out_bytes );
close(FILE);

my $in_traffic = sprintf( "%.2lf",
	( $in_bytes - $last_in_bytes ) / ( time - $last_check_time ) );
my $out_traffic = sprintf( "%.2lf",
	( $out_bytes - $last_out_bytes ) / ( time - $last_check_time ) );

my $in_traffic_absolut  = sprintf( "%.0f", $last_in_bytes );
my $out_traffic_absolut = sprintf( "%.0f", $last_out_bytes );

my $in_usage  = sprintf( "%.1f", ( 1.0 * $in_traffic * 100 ) / $iface_speed );
my $out_usage = sprintf( "%.1f", ( 1.0 * $out_traffic * 100 ) / $iface_speed );

$in_bytes  = sprintf( "%.2f", $in_bytes);
$out_bytes = sprintf( "%.2f", $out_bytes);

my $exit_status = "OK";

if ( $opt_output eq "Bytes" ) {
	$output = "Total RX Bytes: $in_bytes B, Total TX Bytes: $out_bytes B<br>";
	$output .=
	    "Average Traffic: $in_traffic "
	  . "B/s ("
	  . $in_usage
	  . "%) in, $out_traffic "
	  . "B/s ("
	  . $out_usage
	  . "%) out";
} else {
	$output = sprintf( "Total RX bits: %u  B, Total TX Bytes: %u bits<br>"
		, $in_bytes * 8, $out_bytes * 8 );
	$output .=
	    "Average Traffic: "
          . $in_traffic * 8
	  . " bit/s ("
	  . $in_usage
	  . "%) in, "
	  . $out_traffic * 8
	  . " bit/s ("
	  . $out_usage
	  . "%) out";
}


if ( ( $in_usage > $crit_usage ) or ( $out_usage > $crit_usage ) ) {
	$exit_status = "CRITICAL";
}

if (   ( $in_usage > $warn_usage )
	or ( $out_usage > $warn_usage ) && $exit_status eq "OK" )
{
	$exit_status = "WARNING";
}

$output .= "<br>$exit_status bandwidth utilization."
  if ( $exit_status ne "OK" );

$warn_abs=sprintf("%.0f", $iface_speed/100*$warn_usage);
$crit_abs=sprintf("%.0f",$iface_speed/100*$crit_usage);
if ( $opt_output eq "Bytes" ) {
	$output .= "|inUsage=$in_usage%;$warn_usage;$crit_usage;; "
		. "outUsage=$out_usage%;$warn_usage;$crit_usage;; "
		. "inAbsolut=".$in_traffic_absolut."B;$warn_abs;$crit_abs;; "
		. "outAbsolut=".$out_traffic_absolut."B;$warn_abs;$crit_abs;;\n";
} else {
	$output .= "|inUsage=$in_usage%;$warn_usage;$crit_usage;; "
		. "outUsage=$out_usage%;$warn_usage;$crit_usage;; "
		. "inAbsolut=" . $in_traffic_absolut * 8 . "bit;" 
		. $warn_abs * 8 .";" . $crit_abs * 8 . ";; "
		. "outAbsolut=" . $out_traffic_absolut * 8 . "bit;"
		. $warn_abs * 8 . ";" . $crit_abs  * 8 . ";;\n";
}

print $output;
exit( $STATUS_CODE{$exit_status} );

sub fetch_ifdescr {
	my $state;
	my $response;

	my $snmpkey;
	my $answer;
	my $key;

	my ( $session, $ifdescr ) = @_;

	if ( !defined( $response = $session->get_table($snmpIfDescr) ) ) {
		$answer = $session->error;
		$session->close;
		$state = 'CRITICAL';
		$session->close;
		exit $STATUS_CODE{$state};
	}

	foreach $key ( keys %{$response} ) {
		if ( $response->{$key} =~ /^$ifdescr$/ ) {
			$key =~ /.*\.(\d+)$/;
			$snmpkey = $1;
		}
	}
	unless ( defined $snmpkey ) {
		$session->close;
		$state = 'CRITICAL';
		printf "$state: Could not match $ifdescr \n";
		exit $STATUS_CODE{$state};
	}
	return $snmpkey;
}

#added 20050416 by mw
#Converts an input value to value in bits
sub bits2bytes {
	return unit2bytes(@_) / 8;
}

# Herbert Straub: calculate the unit bytes (octets).
sub unit2bytes {
	my ( $value, $unit ) = @_;

	$unit = lc( $unit );
	if ( $unit eq "t"  or $unit eq "tbits" ) {
		return $value * 1000 * 1000 * 1000 * 1000;
	} elsif ( $unit eq "g" or $unit eq "gbits") {
		return $value * 1000 * 1000 * 1000;
	} elsif ( $unit eq "m" or $unit eq "mbits") {
		return $value * 1000 * 1000;
	} elsif ( $unit eq "k" or $unit eq "kbits") {
		return $value * 1000;
	} elsif ( $unit eq "b" ) {
		return $value;
	} elsif ( $unit eq "tibits" ) {
		return $value * 1024 * 1024 * 1024 *1024;
	} elsif ( $unit eq "gibits" ) {
		return $value * 1024 * 1024 * 1024;
	} elsif ( $unit eq "mibits" ) {
		return $value * 1024 * 1024;
	} elsif ( $unit eq "kibits" ) {
		return $value *1024;
	} else {
		print "You have to supply a supported unit\n";
		exit $STATUS_CODE{'UNKNOWN'};
	}
}

#This function detects if an overflow occurs. If so, it returns
#a computed value for $bytes.
sub counter_overflow {
	my ( $bytes, $last_bytes, $max_bytes ) = @_;

	$bytes += $max_bytes if ( $bytes < $last_bytes );
	$bytes = 0 if ( $bytes < $last_bytes );
	return $bytes;
}

sub print_usage {
	print <<EOU;

    Copyright (C) 2004 Gerd Mueller / Netways GmbH
    Copyright (C) 2006,2007,2009,2011 Herbert Straub <herbert\@linuxhacker.at>

    Version: $version

    Usage: check_iftraffic.pl -H host -i if_descr -b if_max_speed [ -w warn ] [ -c crit ]


    Options:

    -h --help
        This text.

    -l --license
        The license information.

    -H --host STRING or IPADDRESS
        Check interface on the indicated host.

    -C --community STRING 
        SNMP Community.

    -s --snmp_version 1 | 2 | 2c
        Specify the snmp version. The current version supports 1 and 2c.

    -i --interface STRING
        Interface Name

    -b --bandwidth INTEGER
        Interface maximum speed in kilo/mega/giga/Bits per second. See
        the units options for details. This value is used for the
        warning and critical threshold calculation.

    -u --units STRING
	Specify the unit of the bandwith options
        Possible values for binary prefix:
	  Tibit = tebibits/s ( 2 ** 40 bits )
          Gibit = gibibits/s ( 2 ** 30 bits )
	  Mibit = mebibits/s ( 2 ** 20 bits )
	  Kibit = kibibits/s ( 2 ** 10 bits )

	Possible values for decimal prefix
	  Tbit = terabits/s ( 10 ** 12 )
	  Gbit = gigabits/s ( 10 ** 9 )
	  Mbit = megabits/s ( 10 ** 6 )
	  kbit = kilobits/s ( 10 ** 3 )

	  b = bits/s

        Compatibility to older version of check_iftraffic
	  g = Gbit
	  m = Mbit
	  k = kbit

        The unit string is not case sensitive.

	For a detailed description read:
          http://en.wikipedia.org/wiki/Gibit
          http://en.wikipedia.org/wiki/Gbit

    -o --output Bytes | bits (default is Bytes)
        Specify the output unit. The default is Bytes/s
	For a detailed description read:
	  http://en.wikipedia.org/wiki/Bit
          http://en.wikipedia.org/wiki/Bytes

    -w --warning INTEGER
        % of bandwidth usage necessary to result in warning status.
        Default: 85%

    -c --critical INTEGER
        % of bandwidth usage necessary to result in critical status.
        Default: 98%

    -M --max INTEGER
	Max Counter Value of net devices in kilo/mega/giga/bytes.

    -d --directory STRING
        Directory for temporary and history files.

    -x --history
        Writing history in temporary file - for debugging purposes.

    -v --version
        Print version information.

    The latest and greatest version of check_iftraffic can be found on:
    http://www.linuxhacker.at
 
EOU

	exit( $STATUS_CODE{"UNKNOWN"} );
}

sub print_license {
	print <<EOU;

        Copyright (C) 2004 Gerd Mueller / Netways GmbH
        Copyright (C) 2006,2007,2009,2011 Herbert Straub <herbert\@linuxhacker.at>

        This program is free software; you can redistribute it and/or
        modify it under the terms of the GNU General Public License
        as published by the Free Software Foundation; either version 2
        of the License, or (at your option) any later version.

        This program is distributed in the hope that it will be useful,
        but WITHOUT ANY WARRANTY; without even the implied warranty of
        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
        GNU General Public License for more details.

        You should have received a copy of the GNU General Public License
        along with this program; if not, write to the Free Software
        Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307

EOU
}

sub print_version {
	print "Version: $version\n";
}
