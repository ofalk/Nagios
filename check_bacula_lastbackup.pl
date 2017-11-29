#!/usr/bin/perl

# Author: Michael Wyraz
# Much code copied from check_mail_loop.pl which is GPL licensed. So this code has the same license.
#
# Checks the age of the last successfull backup of a given client and (optional) of a given level.
#

use strict;
use Getopt::Long;
use Time::Local;

use Env qw/NAGIOS_HOSTNAME/;

&Getopt::Long::config('auto_abbrev');

my $bconsoleCommand="/usr/sbin/bconsole";
my $level="*";
my $levelName;
my $client;
my $warningAge=24;
my $criticalAge=48;

my %ERRORS = ('OK' , '0',
              'WARNING', '1',
              'CRITICAL', '2',
              'UNKNOWN' , '3');

# Subs declaration
sub usage;
sub nsexit;

# Evaluate Command Line Parameters
my $status = GetOptions(
                        "bconsole-command=s",\$bconsoleCommand,
                        "level=s",\$level,
                        "client=s",\$client,
                        "warningAge=i",\$warningAge,
                        "criticalAge=i",\$criticalAge,
                        );
# If not specified on command line (which will not be empty, but '$'),
# try to use environment variable
$client = $NAGIOS_HOSTNAME if $client eq '$';

if ($status == 0 || !($client && $bconsoleCommand) ) {
  usage();
}

if ($level eq "*") {
  $levelName="backup";
}
elsif ($level eq "F" || $level eq "f") {
  $level="F";
  $levelName="FULL backup";
}
elsif ($level eq "I" || $level eq "i") {
  $level="I";
  $levelName="INCREMENTAL backup";
}
elsif ($level eq "D" || $level eq "d") {
  $level="D";
  $levelName="DIFFERENTIAL backup";
}
else {
  usage();
}



# restrict client names to a-z,A-Z,0-9,".","_","-" to avoid execution of shell commands
if (!($client=~m/^[a-zA-Z0-9\.\-_]+$/i)) {
  nsexit ("INVALID CLIENT NAME","ERROR");
}

open (JOBLIST,"echo 'list jobname=$client' | $bconsoleCommand |");

my $latestBackupAge=-1;
my $jobStatus;

while(<JOBLIST>) {
  my($line) = $_;
  # split into columns (and remove whitespaces)
  my ($_dummy,$_jobId,$_client,$_startTime,$_type,$_level,$_jobFiles,$_jobBytes,$_jobStatus)=split(/\s*\|\s*/,$line);

  if ( $_jobStatus ne 'T' and $_jobStatus ne 'R') {
    next; # only jobs which terminated correctly
  } else {
    $jobStatus = $_jobStatus;
  }
  if ( $_client ne $client ) {
    next; # only jobs for this client
  }
  if (!( $level eq "*" || $_level eq $level )) {
    next; # only jobs for the required level (or any if $level="*")
  }
  if($level eq '*') {
    if($_level eq 'I') {
      $levelName = 'INCREMENTAL backup';
    } elsif($_level eq 'F') {
      $levelName = 'FULL backup';
    } elsif($_level eq 'D') {
      $levelName = 'DIFFERENTIAL backup';
    } else {
      $levelName = 'backup';
    }
  }

  my ($_y,$_m,$_d,$_H,$_M,$_S);

  ($_y,$_m,$_d,$_H,$_M,$_S) = ( $_startTime=~/^(\d{4})\-(\d{2})\-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})$/ );

  if (! $_y ) {
    next; # require valid startTime
  }

  my $_startTimeAsUnixtime=timelocal($_S, $_M, $_H, $_d, $_m-1, $_y);
  my $backupAgeInSeconds=time()-$_startTimeAsUnixtime;

  if ($backupAgeInSeconds>0) {
    if ($latestBackupAge < 0 || $latestBackupAge > $backupAgeInSeconds) {
      $latestBackupAge=$backupAgeInSeconds;
    }
  }
}

my $result;
my $status;

if ($latestBackupAge<0) {
  $result="Unable to find a valid $levelName for $client";
  $status="CRITICAL";
} else {
  $result="Last $levelName for $client ";
  if($jobStatus eq 'R') {
    $result .= "started ";
  } else {
    $result .= "was ";
  }
  $result.=sprintf ("%02D:%02D hours", $latestBackupAge/3600,($latestBackupAge/60) %60);
  $result.=' ago';
  if($jobStatus eq 'R') {
    $result.= ' and is still running';
  } else {
    $result.= '.';
  }
  if ($latestBackupAge/3600 > $criticalAge ) {
    $status="CRITICAL";
  } elsif ($latestBackupAge/3600 > $warningAge) {
    $status="WARNING";
  } else {
    $status="OK";
  }
}

nsexit($result,$status);


sub usage {
  print "check_bacula_lastbackup.pl 1.0 Nagios Plugin\n";
  print "\n";
  print "=" x 75,"\nERROR: Missing or wrong arguments!\n","=" x 75,"\n";
  print "\n";
  print "This script checks before how many hours the last successfull\n";
  print "backup of a certain client was done.\n";
  print "\n";
  print "\nThe following options are available:\n";
  print "   -bconsole-command=path    path to the bconsole command ($bconsoleCommand)\n";
  print "   -client=text              bacula client to check\n";
  print "   -level=[*|F|D|I]          level of backup to check (*=any, F=full, D=differential, I=incremental - default: any)\n";
  print "   -warningAge=hours         if the last backup is older than $warningAge hours, status is warning\n";
  print "   -criticalAge=hours        if the last backup is older than $criticalAge hours, status is critical\n";
  print "\n";
  print " Options may abbreviated!\n";
  print "This script comes with ABSOLUTELY NO WARRANTY\n";
  print "This programm is licensed under the terms of the ";
  print "GNU General Public License\n\n";
  exit $ERRORS{"UNKNOWN"};
}


sub nsexit {
  my ($msg,$code) = @_;
  print "$code: $msg\n" if (defined $msg);
  exit $ERRORS{$code};
}
