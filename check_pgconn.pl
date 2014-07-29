#!/usr/bin/perl
use DBI;

# Partially cleaned up version from
# https://www.monitoringexchange.org/inventory/Check-Plugins/Database/PostgreSQL/check_pgsql_connections
# by Oliver Falk <oliver@linux-kernel.at>, 2014

use strict;
use warnings;

use Getopt::Long;

my $host;
my $dbname = 'postgres';
my $dbuser = 'postgres';
my $warn = 70;
my $crit = 80;

GetOptions(
	"host|h=s"	=> \$host,
	"dbname|d=s"	=> \$dbname,
	"dbuser|u=s"	=> \$dbuser,
	"warning|w=i"	=> \$warn,
	"critical|c=i"	=> \$crit,
);

if($warn > $crit) {
	print "Warning level ($warn) must be greater than critical level ($crit)\n";
	exit -1;
}

unless($host) {
	print "Provide an IP or hostname using --host\n";
	exit -1;
}

# Default to UNKNOWN status
my $status = 3;

my $Con = "DBI:Pg:dbname=$dbname;host=$host";
my $Dbh = DBI->connect($Con, $dbuser, '', {
	RaiseError => 1
}) || die "Unable to access Database $dbname on host $host as user $dbuser.\nError returned was: ". $DBI::errstr;

my $sql_max = "SHOW max_connections;";
my $sth_max = $Dbh->prepare($sql_max);
$sth_max->execute();
my $max_conn;
while (my ($mconn) = $sth_max->fetchrow()) {
	$max_conn = $mconn;
}

my $sql_curr = "SELECT COUNT(*) FROM pg_stat_activity;";
my $sth_curr = $Dbh->prepare($sql_curr);
$sth_curr->execute();
my $curr_conn;
while ((my $conn) = $sth_curr->fetchrow()) {
	$curr_conn = $conn;
}
my $avail_conn = $max_conn-$curr_conn;
my $avail_pct = $avail_conn/$max_conn*100;
my $used_pct = sprintf("%2.1f", $curr_conn/$max_conn*100);

if ($avail_pct < (100 - $warn) || $avail_conn < (100 - $warn)) {
	$status = 2;
} elsif ($avail_pct < (100 - $crit) || $avail_conn < (100 - $crit)) {
	$status = 1;
} else {
	$status = 0;
}
my $msg = "$curr_conn of $max_conn Connections Used ($used_pct%) | used=$used_pct%;$warn;$crit;;\n";

print $msg;
exit $status;
