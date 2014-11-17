#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
Getopt::Long::Configure ('auto_version');
Getopt::Long::Configure ('auto_help');
use Data::Dumper;
use DBI;
use CGI qw/:standard -oldstyle_urls/;
use Sys::Hostname;
use Switch;
use YAML qw/LoadFile Load/;
use File::Spec;
use Hash::Merge qw/merge/;
Hash::Merge::set_behavior('RIGHT_PRECEDENT');

select(STDERR); $| = 1;
select(STDOUT); $| = 1;

# see pod for more information
my $defconfig = Load('
ssh_user: root
command_apply: yum -y upgrade
command_list: yum check-update
ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no

db:
  driver: DBI:mysql
  name: update_logs
  user: root
  pass:
  port: 
  host: localhost
');

# This will not work on Windows. But we do not support Windows. :-P
my $configfile = File::Spec->catfile((File::Spec->splitpath(File::Spec->rel2abs($0)))[1], 'yum_updates_by_ssh.yml');

my $lclconfig = {};
$lclconfig = LoadFile($configfile) if -s $configfile;
my $config = merge($defconfig, $lclconfig);

sub getdbh {
	my $dsn = $config->{db}->{driver}. ':database=' . $config->{db}->{name} . ';host=' . $config->{db}->{host};
	$dsn .= 'port=' . $config->{db}->{port} if $config->{db}->{port};
	return DBI->connect($dsn, $config->{db}->{user}, $config->{db}->{pass});
}

our $VERSION = '0.1';

use constant ERRORS => {
	'OK'		=> 0,
	'WARNING'	=> 1,
	'CRITICAL'	=> 2,
	'UNKNOWN'	=> 3,
};

# Our exit subrouting... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	print $mesg . "\n" if $mesg;
	exit ERRORS->{$code};
}

my $dbh = getdbh();

my $mode = param('mode');
my $host = param('host');
my $debug = param('debug');

my ($clhost, $cldebug, $clmode);
# In case we're run via command line
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
        "host|h=s"      => \$clhost,
        "debug|d"       => \$cldebug,
	"mode|m=s"	=> \$clmode,
);
$mode = $clmode if $clmode;
$host = $clhost if $clhost;
$debug = $cldebug if $cldebug;
my $cmdinvoc = 1 if($clmode||$clhost||$cldebug); 

print header, start_html('Apply updates') unless $cmdinvoc;
unless($host) {
	print "<p align=\"center\">" unless $cmdinvoc;
	print "No host given\n";
	print "</p>\n", end_html unless $cmdinvoc;
	exit 0;
}

#print "<!--\n";
#print "DEBUG:\n";
#use Data::Dumper;
#print Dumper(%ENV);
#print "-->";

my $user = $ENV{REMOTE_USER} || $ENV{AUTHENTICATED_UID} || 'Unknown';

sub links {
	print "<a href=\"" . url(-path_info=>1) . "?mode=run&host=$host\" target=\"_new\">Apply updates</a><br/>";
	print "<a href=\"" . url(-path_info=>1) . "?mode=listlogs&host=$host\" target=\"_new\">List update logs</a><br/>";
	print "<a href=\"" . url(-path_info=>1) . "?mode=list&host=$host\" target=\"_new\">List updates</a>";
};

$mode = 'list' unless $mode;

# Create admin user hash, for easy access
my $admins;
foreach(@{$config->{admins}}) {
	$admins->{$_} = 1;
}

local $SIG{ALRM} = sub { print " "; alarm 5; };

# Check which mode we should run
if($mode eq 'run') {
	unless($cmdinvoc) {
		unless($admins->{$user}) {
			print "<center><b>Unauthorized</b></center><p/>\n";
			print "Only following users are allowed to run updates: " . join(', ', keys %{$admins}) . "<p/>";
			links();
			print end_html;
			exit 0;
		}
	}
	my $cmdline = "ssh -t $host -l " . $config->{ssh_user} . ' ' . $config->{ssh_opts} . ' "' . $config->{command_apply} . '"';
	print 'DEBUG: ' . $cmdline . "\n" if $debug;
	open(FH, $cmdline . '|') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
	my $nolines = 0;
	my @lines;
	print "<pre>\n" unless $cmdinvoc;
	alarm 10 unless $cmdinvoc;
	while(<FH>) {
		alarm 5 unless $cmdinvoc;
		$nolines++;
		chomp;
		push @lines, $_;
		print $_ . "\n";
	}
	alarm 0 unless $cmdinvoc;
	print "</pre>\n" unless $cmdinvoc;
	close(FH);

	if($nolines < 1) {
		print "<center>\n" unless $cmdinvoc;
		print "Remote command execution on '$host' failed - not enough data received\n";
		print "</center>\n" unless $cmdinvoc;
		print end_html unless $cmdinvoc;
		exit 0;
	}

	print "<p>" unless $cmdinvoc;
	print "Commiting logs ...";
	$dbh->begin_work;
	my $ts = $dbh->selectcol_arrayref("SELECT now()");
	$ts = @{$ts}[0];
	my $sth = $dbh->prepare("INSERT INTO logs (host, line, ts, who) values (?, ?, ?, ?)");
	foreach(@lines) {
		next if $_ =~ /^Loaded plugins:/;
		next if $_ =~ /^This system is receiving updates/;
		next if $_ =~ /^Setting up Upgrade Process/;
		next if $_ =~ /^No Packages marked for Update/;
		$sth->bind_param(1, $host);
		$sth->bind_param(2, $_);
		$sth->bind_param(3, $ts);
		$sth->bind_param(4, $user);
		$sth->execute();
	}
	$dbh->commit;
	print " Done\n";
	print "</p>" unless $cmdinvoc;
	links() unless $cmdinvoc;
	print '<p>' unless $cmdinvoc;
	print "[Rescheduled check of Updates]\n";
	print '</p>' unless $cmdinvoc;
	exec "/usr/local/bin/reschedule.pl --host $host --service Updates";
	print end_html unless $cmdinvoc;
	exit 0;
} elsif($mode eq 'listlogs') {
	my $sth = $dbh->prepare("SELECT line, ts, who FROM logs WHERE host = ?");
	$sth->bind_param(1, $host);
	$sth->execute;
	my $lastts = '';
	print "<pre>" unless $cmdinvoc;
	while($_ = $sth->fetchrow_hashref()) {
		if($lastts) {
			if($lastts ne $_->{ts}) {
				print "="x79 . "\n";
			}
		}
		print "$_->{who}\@$_->{ts} $_->{line}" . "\n";
		$lastts = $_->{ts};
	}
	print "</pre>" unless $cmdinvoc;
	links() unless $cmdinvoc;
	print end_html unless $cmdinvoc;
	exit 0;
} else { # default is to just list the currently available updates
	my $cmdline = "ssh -t $host -l " . $config->{ssh_user} . ' ' . $config->{ssh_opts} . ' "' . $config->{command_list} . '"';
	print 'DEBUG: ' . $cmdline . "\n" if $debug;
	open(FH, $cmdline . '|') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
	my $nolines = 0;
	my @lines;
	print "<pre>\n" unless $cmdinvoc;
	alarm 10 unless $cmdinvoc;
	while(<FH>) {
		alarm 5 unless $cmdinvoc;
		$nolines++;
		chomp;
		push @lines, $_;
		print $_ . "\n";
	}
	alarm 0 unless $cmdinvoc;
	print "</pre>\n" unless $cmdinvoc;
	close(FH);

	if($nolines < 1) {
		print "<center>\n" unless $cmdinvoc;
		print "Remote command execution on '$host' failed - not enough data received\n";
		print "</center>\n" unless $cmdinvoc;
		print end_html unless $cmdinvoc;
		exit 0;
	}
	links() unless $cmdinvoc;
	print end_html unless $cmdinvoc;
	exit 0;
}

1;

__END__

=head1 NAME

yum_updates_by_ssh.pl

=head1 SYNOPSIS

    yum_updates_by_ssh.pl --host <hostname or ip_address> [--debug] [--mode run|list|listlogs]

=head1 DESCRIPTION

Script/CGI to apply update via yum on a specific host and log the update run to some
database.

=head1 DATABASE LAYOUT

CREATE TABLE logs (
       id              int NOT NULL AUTO_INCREMENT,
       host            varchar(256) NOT NULL,
       line            text,
       ts              timestamp NOT NULL,
       PRIMARY KEY (id)
);

=head1 CONFIGURATION

=head2 OVERRIDING THE DEFAULTS

 Add the following content to a file called yum_updates_by_ssh.yml
 if you need to override the defaults. Any values in the config file
 will override the defaults - so no need to copy the defaults, if you
 do not need to change them.

 ssh_user: root
 command_apply: yum -y upgrade
 command_list: yum check-update
 ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
 admins:
  - admin123

 db:
   driver: DBI:mysql
   name: update_logs
   user: root
   pass:
   port: 
   host: localhost

=head2 APACHE

 Add the following (or similar) alias to your apache configuration.
 In case you use OMD - this fits best in the 'site.conf'.

 ScriptAlias /test/yum_updates_by_ssh.pl /opt/nagios/plugins/yum_updates_by_ssh.pl

=head2 NAGIOS / OMD

 Define the extended service information, so you can list updates
 directly from within the Nagios interface (I suggest to use Thruk!).
 Note: You could also use the action URL, but usually it's used for PNP
 and the notes URL is usually free.
 On the list interface there's an apply button to run the update process.

 define serviceextinfo{
        host_name               somehost
        service_description     Updates
        notes_url               /test/yum_updates_by_ssh.pl.pl?mode=list&host=$HOSTNAME$
 }

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
