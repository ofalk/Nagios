#!/usr/bin/perl

# Copyright by markus trimmel
# do not blame me! :-)

use strict;
use warnings;
use Getopt::Long;
use File::Basename;

# Vars

my $min = "0";
my $max = "0";
my $crit;
my $warn;
my $line;
my $key;
my $backup;
my $restore;
my $srcrepl;
my $dstrepl;
my $synthetic;
my $total;
my $string;
my $retval;
my $retmessage;
my $script = basename $0;
my $host;
my $result;
my @OUT;

# GetOpt

$result = GetOptions ("host=s"   => \$host);

if(!$host){
  print "Usage: $script -h <data domain> \n";
  exit 1;
}

#################################################################################
# Contact DataDomain

open(FH,"ssh ddboost\@$host ddboost show connections 2>&1 |") or die;
@OUT = <FH>;
close FH;

# Find maxmimum
MAX:for $line (@OUT){
    $line =~ s/\n//g;
    if("$line" =~ /Max Client Connections/g){
      ($key,$crit) = split(/:/,"$line");
      $crit =~ s/\s//g;
      last MAX;
    }
}

if("$crit" ne ""){
   $warn = $crit/100*80;

   # Parse Performance values, quit with first hit
   VAL: for $line (@OUT){
       $line =~ s/\n//g;
       if("$line" =~ /Total Connections/g){
         $line =~ s/\s\s+/ /g;
         $line =~ s/^\s+//g;
         ($key,$string) = split(/: /,"$line");
         ($backup,$restore,$srcrepl,$dstrepl,$synthetic,$total) = split(/ /,"$string");
         last VAL;
       }
   }
}

# Return Output

if("$crit" eq ""){
   $retval = "3";
   $retmessage = "UNKNOWN";
}
elsif("$total" < "$warn"){
   $retval = "0";
   $retmessage = "OK";
}
elsif("$total" >= "$crit"){
   $retval = "2";
   $retmessage = "CRITICAL";
}
elsif("$total" >= "$warn"){
   $retval = "1";
   $retmessage = "WARNING";
}

print "$retmessage DDBOOSTCON | backup=$backup;;;; restore=$restore;;;; srcrepl=$srcrepl;;;; dstrepl=$dstrepl;;;; synthetic=$synthetic;;;; total=$total;$warn;$crit;;\n";

exit $retval;
