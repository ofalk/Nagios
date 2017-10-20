#!/usr/bin/perl

# Copyright by Oliver Falk

use strict;
use warnings;
use Getopt::Long;
use File::Basename;

my $script = basename $0;
my $host;
my @OUT;
my $perfdata = '';
my $output = '';

# GetOpt

my $result = GetOptions ("host=s"   => \$host);

if(!$host){
  print "Usage: $script -h <data domain> \n";
  exit 1;
}

#################################################################################
# Contact DataDomain

my $i = 0;
open(FH,"ssh nagios\@$host mtree list 2>&1 |") or die;
while (<FH>) {
	$i++;
	next unless /^\/data\//;
	my($vol, $space, $status) = split(/\s+/, $_);
	$output .= "$vol($status) = $space\n";
	$perfdata .= "$vol=$space;;;; ";
}
close FH;
$perfdata =~ s/ $//g;
chomp($output);

if($i < 3) {
	print "UNKNOWN: Not enough data received - connection issues!?\n";
	exit 3;
} else {
	print "OK\n$output |\n$perfdata\n";
	exit 0;
}

1;
