#!/usr/bin/perl -w
# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2013-2014
# Partially reused code snippets from check_sap_rfcping.pl

use POSIX;
use strict;
use Getopt::Long;

use lib ".";
use lib qw(/usr/lib64/nagios/plugins/ /usr/lib/nagios/plugins);
use lib qw(/opt/omd/versions/1.10/lib/nagios/plugins/);

use utils qw(%ERRORS);

use constant MSPROT		=> "/usr/local/bin/msprot";
use constant DEFAULT_TIMEOUT	=> 30;

# please modify if you havn't defined the rfcsdk libraries globally via 
# /etc/ld.so.conf (ldconfig)

$ENV{'LD_LIBRARY_PATH'}         =  '/usr/local/rfcsdk/lib/'; 

my $PROGNAME = "check_sap_msprot";
my $VERSION = "0.1";

my ($host, $port);
my $timeout = 30;
my $result = GetOptions (
	"port|p=i"		=> \$port,
	"mshost|h|host=s"	=> \$host,
	"timeout|t=i"		=> \$timeout,
);

# set alarmhandler for timeout handling
$SIG{'ALRM'} = sub {
  print ("ERROR: plugin timed out after $timeout seconds \n");
  exit $ERRORS{"UNKNOWN"};
};

alarm($timeout);

if(!$port || !$host || !$timeout) {
	print "No host, no port or no timeout specified!\n";
	exit $ERRORS{"UNKNOWN"};
}

# check if command exists and executable flag is set
if ( ! -X MSPROT ) {
  printf ("ERROR: Command %s not found or not executable\n",MSPROT);
  exit $ERRORS{"UNKNOWN"};
}

my $msprot_cmd = MSPROT . " -l -mshost $host -msserv $port -s -d J2EE";

if ( ! open(FH, "$msprot_cmd |") ) {
  print ("ERROR: can not execute $msprot_cmd \n");
  exit $ERRORS{"UNKNOWN"};
}

my $output = '';
my $found = 0;
while(<FH>) {
	$output .= $_;
	if(/LIST/ && /rfcengine/) {
		$found = 1;
	}
}
close(FH);
my $rc=$? >> 8;

unless($output) {
	print "UNKNOWN: No output from msprot!\n";
	exit $ERRORS{"UNKNOWN"};
}

if($rc) {
	print "UNKNOWN: Return code $rc != 0!\n";
	print "Output from command follows:\n$output";
	exit $ERRORS{"UNKNOWN"};
}

unless($found) {
	print "CRITICAL: No listening rfcengine found in output!\n";
	print "Output from command follows:\n$output";
	exit $ERRORS{"CRITICAL"};
}

print "OK: Found rfcengine in listening status!\n";
print "Output from command follows:\n$output";
exit $ERRORS{'OK'};
