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

# see pod for more information
my $defconfig = Load('
check_by_ssh: /opt/omd/versions/1.10/lib/nagios/plugins/check_by_ssh
ssh_user: root
command: grep ^root /etc/shadow
ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
check_by_ssh_opts: -E -t 180

db:
  driver: DBI:mysql
  name: rootpw
  user: rootpw
  pass: security
  port: 
  host: localhost
');

# This will not work on Windows. But we do not support Windows. :-P
my $configfile = File::Spec->catfile((File::Spec->splitpath(File::Spec->rel2abs($0)))[1], 'check_rootpw_by_ssh.yml');

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

my ($host, $debug);
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"debug|d"	=> \$debug,
);

# Command line mode 9-}
if($result && !param()) {
	do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;

	my $sth = $dbh->prepare("SELECT hash, host FROM rootpw WHERE host = ?");
	$sth->bind_param(1, $host);
	$sth->execute();
	my $db_hsh = $sth->fetchall_hashref('host');
	my $fs_hsh;

	my $cmdline = $config->{check_by_ssh} . ' -H ' . " $host " . $config->{check_by_ssh_opts}. ' -l ' . $config->{ssh_user} . ' ' . $config->{ssh_opts} . ' -C "' . $config->{command} . '"';
	print 'DEBUG: ' . $cmdline . "\n" if $debug;
	open(FH, $cmdline . '|') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
	my $nolines = 0;
	my $hash;
	while(<FH>) {
		my $user;
		$nolines++;
		chomp;
		@_ = split(/:/, $_);
		$hash = $_[1];
	}
	close(FH);

	do_exit('UNKNOWN', "Remote command execution on '$host' failed - not enough data received") if $nolines < 1;

	# No run before - empty hash
	unless(keys %{$db_hsh}) {
		# Add all
		$dbh->begin_work;
		$sth = $dbh->prepare("INSERT INTO rootpw (host, hash) values (?, ?)");
		$sth->bind_param(1, $host);
		$sth->bind_param(2, $hash);
		$sth->execute();
		$dbh->commit;
		do_exit('OK', 'Initial check was successful | changed=0;1;1;');
	} else {
		# Check if changed
		unless($db_hsh->{$host}->{hash} eq $hash) {
			do_exit('CRITICAL', "Password hash change found! | changed=1;1;1;");
		} else {
			do_exit('OK', 'Zero changes | changed=0;1;1;');
		}
	}
} else {
	# CGI mode
	my $mode = param('mode');
	$mode = '' unless $mode;

	# For command line testing...
	$host = param('host') if param('host');

	unless($host) {
		print header, start_html('ROOTPW - error');
		print "<p align=\"center\">No host given</p>\n";
		print end_html;
		exit 0;
	}
	if(param('op') eq 'ack') {
		print header, start_html('ROOTPW acknowledgement');
		sub removehash {
			my $sth;

			# Check if this host is available on this database
			$sth = $dbh->prepare("SELECT count(*) AS count from rootpw WHERE host = ?");
			$sth->bind_param(1, $host);
			$sth->execute();
			my $res = $sth->fetchrow_arrayref();
			return if @{$res}[0] == 0; # Nothing here, so we get back to our caller, probably other db host

			# delete entry, so I can be rechecked next time
			$sth = $dbh->prepare("DELETE FROM rootpw WHERE host = ?");
			$sth->bind_param(1, $host);
			$sth->execute();

			print "<p align=\"center\">Done on $config->{db}->{host}</p>\n";
		}
		# 'Local' database
		removehash();

		# Remote databases (prune_db)
		if($config->{prune_db}) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
    				$dbh = getdbh();
					removehash();
				}
			} else {
				print "<p align=\"center\">I'm afraid, but your prune_db configuration is WRONG!</p>\n";
			}
		}
	}
	print end_html;
}

1;

__END__

=head1 NAME

check_rootpw_by_ssh.pl

=head1 SYNOPSIS

    check_rootpw_by_ssh.pl -h <hostname or ip_address>

=head1 DESCRIPTION

Nagios script to check root password hash via SSH - database driven

The script also provides a web interface to acknowledge a
password change. Eg. Monthly root password change.

=head1 DATABASE LAYOUT

CREATE TABLE rootpw (
        host            varchar(256) UNIQUE,
        hash            varchar(2049) DEFAULT NULL
);

=head1 CONFIGURATION

=head2 OVERRIDING THE DEFAULTS

 Add the following content to a file called check_rootpw_by_ssh.yml
 if you need to override the defaults. Any values in the config file
 will override the defaults - so no need to copy the defaults, if you
 do not need to change them.

 check_by_ssh: /opt/omd/versions/1.10/lib/nagios/plugins/check_by_ssh
 ssh_user: root
 command: grep ^root /etc/shadow
 ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
 check_by_ssh_opts: -E -t 180

 db:
   driver: DBI:mysql
   name: rootpw
   user: rootpw
   pass: security
   port: 
   host: localhost

 There is a very special configuration option for also acknowleding the
 changed hash on a remote host. This is useful if you use distributed
 monitoring and want to allow your administrators to remotely wipe
 the entries. The configuration looks like this (of course, there
 is no default configuration for this):

 prune_db:
   remote_site:
     driver: DBI:mysql
     name: rootpw
     user: rootpw
     pass: security
     host: remote_host

 Note, that for remote sites you always have to provide _all_ database
 parameters, even if user/pass/database name might be the same as the
 local one.
 Yes, you can have several remote sites.
 
 Please be aware that in the current version, it will iterate over all
 remote sites and run the delete query. So if you have hosts with same
 ip addresses or hostnames (depending on your configuration), you'll
 delete all hashes for all the hosts.

=head2 APACHE

 Add the following (or similar) alias to your apache configuration.
 In case you use OMD - this fits best in the 'site.conf'.

 ScriptAlias /test/ackrootpw.pl /opt/nagios/plugins/check_rootpw_by_ssh.pl

=head2 NAGIOS / OMD

 Define a command (take care about the USER5 macro - this is probably
 different in your environment):

 define command {
   command_name    check_rootpw_by_ssh
   command_line    $USER5$/check_rootpw_by_ssh.pl --host $HOSTADDRESS$
 }

 Define a service for your hostgroup(s) (used in this example) or
 your host. Adjust for your needs.

 define service {
        use                     MYTEMPLATE
        hostgroup_name          unixlinux-group,solaris-group
        service_description     rootpw
        check_command           check_rootpw_by_ssh
 }

 Define the extended service information, so you can delete the hashes
 directly from within the Nagios interface (I suggest to use Thruk!).
 Note: You could also use the action URL, but usually it's used for PNP
 and the notes URL is usually free.

 define serviceextinfo{
        hostgroup_name          unixlinux-group,solaris-group
        service_description     rootpw
        notes_url               /test/ackrootpw.pl?op=ack&host=$HOSTADDRESS$
 }

 If you have a SSH check - like I have - you may consider adding a
 service dependency like the following:

 define servicedependency {
        hostgroup_name                  unixlinux-group,solaris-group
        service_description             SSH
        dependent_service_description   rootpw
        notification_failure_criteria   w,c
 }

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2013-2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
