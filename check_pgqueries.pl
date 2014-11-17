#!/usr/bin/perl -w

# Partially cleaned up version from
# https://www.monitoringexchange.org/inventory/Check-Plugins/Database/PostgreSQL/check_pgsql_queries
# by Oliver Falk <oliver@linux-kernel.at>, 2014

use strict;
use warnings;

use DBI;
require DBD::Pg;

use Getopt::Long;

my $host;
my $dbname = 'postgres';
my $dbuser = 'postgres';

GetOptions(
	"host|h=s"	=> \$host,
	"dbname|d=s"	=> \$dbname,
	"dbuser|u=s"	=> \$dbuser,
);


# Default to UNKNOWN status
my $status = 3;

my $vacuum_count = 0;
my $alter_count = 0;
my $update_count = 0;
my $insert_count = 0;
my $select_count = 0;
my $longidle_count = 0;
my $idle_count = 0;
my $nonidle_count;
my $drop_count = 0;
my $create_count = 0;
my $truncate_count = 0;
my $unknown_count = 0;
my $resting_count = 0;
my $copy_count = 0;

my $count = 0;
my $total_count = 0;
my $detail = 0;
my $short_query;

my $msg = '';
my $msg_query_details = '';
my $msg_counts = '';

unless($host) {
	print "Provide an IP or hostname using --host\n";
	exit -1;
}

my $Con = "DBI:Pg:dbname=$dbname;host=$host";
my $Dbh = DBI->connect($Con, $dbuser, '', {RaiseError =>1}) || die "Unable to access Database $dbname on host $host as user $dbuser.\nError returned was: ". $DBI::errstr;

my $sql = "SELECT datname, current_query, timeofday()::TIMESTAMP-query_start, (CASE WHEN timeofday()::TIMESTAMP-query_start > INTERVAL '5 minutes' THEN TRUE ELSE FALSE END) AS slow, usename FROM pg_stat_activity;";

my $sth = $Dbh->prepare($sql);
$sth->execute();
while (my ($datname, $query, $duration, $slow, $username) = $sth->fetchrow()) {
	if ($slow =~ /1/i) {
		if ($query =~ /\<IDLE\>/i) {
			$longidle_count++;
		} else {
			$detail=1;
		}
	}

	# Categorize queries
	if ($query =~ /^SELECT/i) {
		$select_count++;
	} elsif (($query =~ /\<IDLE\>/i) || (length($query) == 0)) {
		$idle_count++;
	} elsif ($query =~ /^INSERT/i) {
		$insert_count++;
	} elsif ($query =~ /^UPDATE/i) {
		$update_count++;
		$detail = 1;
	} elsif ($query =~ /^VACUUM/i) {
		$vacuum_count++;
		$detail = 1;
	} elsif ($query =~ /^CREATE/i) {
		$create_count++;
		$detail = 1;
	} elsif ($query =~ /^DROP/i) {
		$drop_count++;
		$detail = 1;
	} elsif ($query =~ /^TRUNCATE/i) {
		$truncate_count++;
		$detail = 1;
	} elsif ($query =~ /^ALTER/i) {
		$alter_count++;
		$detail = 1;
	} elsif ($query =~ /^COPY/i) {
		$copy_count++;
		$detail = 1;
	} elsif ($query =~/[\t\s]/) {
		# I was attempting to catch any queries with no status, apparently it isn't working
		# The $query field looks like a bunch of spaces
		$resting_count++;
		$detail = 1;
	} else {
		$unknown_count++;
		$detail = 1;
	}

	# if detail is set we do stuff
	if ($detail == 1) {
		$detail = 0;
		$count++;
		$short_query = substr($query,0,18);
		$msg_query_details .= ",$username doing $short_query on $datname for $duration";
	}
	$total_count++;
}

$Dbh->disconnect;

$nonidle_count = $total_count - $idle_count;
		
if ($count > 3) {
	$status = 2;
	} elsif ($count > 1) {
	$status = 1;
} else {
	$status = 0;
}

my $perfdata = "| total=$total_count;;;; ";
	
$msg_counts = "$longidle_count long IDLEs $msg_counts" if $longidle_count > 0;
$perfdata .= "longidle=$longidle_count;;;; ";
$msg_counts = "$resting_count resting $msg_counts" if $resting_count > 0;
$perfdata .= "resting=$resting_count;;;; ";
$msg_counts = "$select_count SELECTs $msg_counts" if $select_count > 0;
$perfdata .= "select=$select_count;;;; ";
$msg_counts = "$insert_count INSERTs $msg_counts" if $insert_count > 0;
$perfdata .= "insert=$insert_count;;;; ";
$msg_counts = "$update_count UPDATEs $msg_counts" if $update_count > 0;
$perfdata .= "update=$update_count;;;; ";
$msg_counts = "$vacuum_count VACUUMs $msg_counts" if $vacuum_count > 0;
$perfdata .= "vacuum=$vacuum_count;;;; ";
$msg_counts = "$alter_count ALTERs $msg_counts" if $alter_count > 0;
$perfdata .= "alter=$alter_count;;;; ";
$msg_counts = "$drop_count DROPs $msg_counts" if $drop_count > 0;
$perfdata .= "drop=$drop_count;;;; ";
$msg_counts = "$create_count CREATEs $msg_counts" if $create_count > 0;
$perfdata .= "create=$create_count;;;; ";
$msg_counts = "$truncate_count TRUNCATEs $msg_counts" if $truncate_count > 0;
$perfdata .= "truncate=$truncate_count;;;; ";
$msg_counts = "$copy_count COPYs $msg_counts" if $copy_count > 0;
$perfdata .= "copy=$copy_count;;;; ";
$msg_counts = "($msg_counts)" if length($msg_counts) > 1;
$msg = "$nonidle_count of $total_count connections are active $msg_counts $msg_query_details $perfdata";
print $msg . "\n";
exit $status;
