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
check_by_ssh: /opt/omd/versions/1.00/lib/nagios/plugins/check_by_ssh
ssh_user: root
command: find /usr/bin/* /usr/sbin/* /sbin/* /bin/* /boot/* /usr/lib* /lib* -maxdepth 1 -type f | xargs md5sum | sort
ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
check_by_ssh_opts: -E -t 180

db:
  driver: DBI:mysql
  name: md5
  user: md5
  pass: checksums
  port: 
  host: localhost
');

# This will not work on Windows. But we do not support Windows. :-P
my $configfile = File::Spec->catfile((File::Spec->splitpath(File::Spec->rel2abs($0)))[1], 'check_md5_by_ssh.yml');

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

	my $sth = $dbh->prepare("SELECT checksum, old_checksum, file, status FROM checksums WHERE host = ?");
	$sth->bind_param(1, $host);
	$sth->execute();
	my $db_hsh = $sth->fetchall_hashref('file');
	my $fs_hsh;

	my $cmdline = $config->{check_by_ssh} . ' -H ' . " $host " . $config->{check_by_ssh_opts}. ' -l ' . $config->{ssh_user} . ' ' . $config->{ssh_opts} . ' -C "' . $config->{command} . '"';
	print 'DEBUG: ' . $cmdline . "\n" if $debug;
	open(FH, $cmdline . '|') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
	my $nolines = 0;
	while(<FH>) {
		$nolines++;
		chomp;
		my ($checksum, $file) = split;

		$fs_hsh->{$file} = $checksum;
	}
	close(FH);
	#print Dumper($fs_hsh) if $debug;

	do_exit('UNKNOWN', "Remote command execution on '$host' failed - not enough data received") if $nolines < 2;

	my ($changed, $added, $removed);

	# No run before - empty hash
	unless(keys %{$db_hsh}) {
		# Add all
		$dbh->begin_work;
		$sth = $dbh->prepare("INSERT INTO checksums (host, file, checksum) values (?, ?, ?)");
		foreach(keys %{$fs_hsh}) {
			$sth->bind_param(1, $host);
			$sth->bind_param(2, $_);
			$sth->bind_param(3, $fs_hsh->{$_});
			$sth->execute();
		}
		$dbh->commit;
		do_exit('OK', 'Initial check was successful | files=' . (scalar keys %{$fs_hsh}) . ';;;changed=0;1;1;added=0;1;1;removed=0;1;1');
	} else {
		# Check for added or deleted files and changed checksums
		foreach(keys %{$fs_hsh}) {
			# File existed before - checksum correct?
			if($db_hsh->{$_}) {
				# If we have an old_checksum, we consider this one
				$db_hsh->{$_}->{checksum} = $db_hsh->{$_}->{old_checksum} if $db_hsh->{$_}->{old_checksum};

				# Special case here. We already added this file
				# as 'added' one.
				if($db_hsh->{$_}->{status} eq 'added') {
					$added->{$_} = {
						old => undef,
						new => $fs_hsh->{$_},
					};
				}

				next if $db_hsh->{$_}->{checksum} eq $fs_hsh->{$_};

				# oops - checksum changed
				$changed->{$_} = {
					old => $db_hsh->{$_}->{checksum},
					new => $fs_hsh->{$_},
				};
			}
			if(!$db_hsh->{$_}) {
				# This has been added - exists in fs_hsh, but not yet in DB
				$added->{$_} = {
					old => undef,
					new => $fs_hsh->{$_},
				};
			}
		}
		# The other way round we just need to check if files have been removed.
		foreach(keys %{$db_hsh}) {
			# File still there? If not...
			if(!$fs_hsh->{$_}) {
				$removed->{$_} = {
					old => $db_hsh->{$_}->{checksum},
					new => undef,
				};
			}
		}

	}

	unless($changed || $added || $removed) {
		# Everything is OK
		do_exit('OK', 'Zero changes | files=' . (scalar keys %{$fs_hsh}) . ';;;changed=0;1;1;added=0;1;1;removed=0;1;1');
	} else {
		my $msg = '';
		if($added) {
			$msg .= "Added files\n";
			$msg .= " + $_ (NEW: $fs_hsh->{$_})\n" foreach keys %{$added};
			my $added_query = 'INSERT INTO checksums (';

			# Add them to the database, but with the status 'added'
			# if not already done
			$dbh->begin_work;
			$sth = $dbh->prepare("INSERT INTO checksums (host, file, checksum, status) values (?, ?, ?, ?)");
			foreach(keys %{$added}) {
				next if $db_hsh->{$_}; # already in the database
				$sth->bind_param(1, $host);
				$sth->bind_param(2, $_);
				$sth->bind_param(3, $added->{$_}->{new});
				$sth->bind_param(4, 'added');
				$sth->execute();
			}
			$dbh->commit;

			
		}
		if($changed) {
			$msg .= "Changed files\n";
			$msg .= " ~ $_ (OLD: $db_hsh->{$_}->{checksum}, NEW: $fs_hsh->{$_}, STATUS WAS: $db_hsh->{$_}->{status})\n" foreach keys %{$changed};

			# Update status in the the database: 'changed'
			# if not already done
			$dbh->begin_work;
			$sth = $dbh->prepare("UPDATE checksums SET status = 'changed', checksum = ?, old_checksum = ? WHERE host = ? AND file = ?");
			foreach(keys %{$changed}) {
				$sth->bind_param(1, $changed->{$_}->{new});
				$sth->bind_param(2, $changed->{$_}->{old});
				$sth->bind_param(3, $host);
				$sth->bind_param(4, $_);
				$sth->execute();
			}
			$dbh->commit;

		}
		if($removed) {
			$msg .= "Removed files\n";
			$msg .= " - $_ (OLD: $db_hsh->{$_}->{checksum}, STATUS WAS: $db_hsh->{$_}->{status})\n" foreach keys %{$removed};

			# Update status in the the database: 'removed'
			# if not already done
			$dbh->begin_work;
			$sth = $dbh->prepare("UPDATE checksums SET status = 'removed' WHERE host = ? AND file = ?");
			foreach(keys %{$removed}) {
				$sth->bind_param(1, $host);
				$sth->bind_param(2, $_);
				$sth->execute();
			}
			$dbh->commit;
		}

		do_exit('CRITICAL', (scalar keys %{$changed}) + (scalar keys %{$added}) + (scalar keys %{$removed}) . " changes found\n$msg | files=" . (scalar keys %{$fs_hsh}) . ';;;changed=' . (scalar keys %{$changed}) . ';1;1;added=' . (scalar keys %{$added}) . ';1;1;removed=' . (scalar keys %{$removed}) . ';1;1');
	}
} else {
	# CGI mode

	my $mode = param('mode');
	$mode = '' unless $mode;

	# For command line testing...
	$host = param('host') if param('host');
	my $history_id = 0;
	$history_id = param('history_id') if param('history_id');

	unless($host || $history_id) {
		print header, start_html('MD5 sums - error');
		print "<p align=\"center\">No host or history id given</p>\n";
		print end_html;
		exit 0;
	}
	if(param('op') eq 'show_history_detail') {
		print header, start_html('MD5 sums - show history details');
		my($sth, $db_hsh);
		$sth = $dbh->prepare("SELECT host, file, status, ts, who FROM v_acked_history WHERE id = ? ORDER BY status");
		$sth->bind_param(1, $history_id);
		$sth->execute();
		my $row = $sth->fetchrow_hashref();

		if($config->{prune_db} && !$row) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
					$dbh = getdbh();
					$sth = $dbh->prepare("SELECT host, file, status, ts, who FROM v_acked_history WHERE id = ? ORDER BY status");
					$sth->bind_param(1, $history_id);
					$sth->execute();
					$row = $sth->fetchrow_hashref();
					last if $row;
				}
			} else {
				print "<p align=\"center\">I'm afraid, but your prune_db configuration is WRONG!</p>\n";
			}
		}
		if($row) {
			print <<EOF;
<center>
<h2>History detail for $row->{host} (db: $config->{db}->{host})</h2>
</center>
<ul>
<li><b>Date</b>: $row->{ts}</li>
<li><b>Who</b>: $row->{who}</li>
</ul>
<center>
<table border="0" style="background-color:#BCB500; font-family:Courier,monospace; font-size:11px">
<tr>
<th width="350px" align="left">File</th>
<th width="240px" align="left">Status</th>
</tr>
<tr><td colspan="2"><hr></td></tr>
EOF
			while(1) {
				my $color = 'green';
				$color = 'yellow' if $row->{status} ne 'ok';
				$color = 'red' if $row->{status} eq 'changed';
				print "<tr style=\"background-color:$color;\"><td>$row->{file}</td><td>$row->{status}</td></tr>\n";
				last unless $row = $sth->fetchrow_hashref();
			}
			print <<EOF;
</table>
</center>
EOF
		} else {
			print "<p align=\"center\">No history data found</p>\n";
		}

	}
	if(param('op') eq 'show') {
		print header, start_html('MD5 sums - show');
		my ($sth, $db_hsh, $history_limit);
		# This variable is used to set the background to a non-transparent
		# color in the "popup" (aka short) mode
		my $additional_h2_style  = '';
		$additional_h2_style = 'style="background-color:#FFFFFF;"' if $mode eq 'short';
		$history_limit = param('history_limit') || 15;
		$history_limit = 100 if $history_limit > 100; # Upper limit.

		# Query for the history
		$sth = $dbh->prepare("SELECT distinct id, ts, who FROM v_acked_history WHERE host = ? ORDER BY ts DESC LIMIT ?");
		$sth->bind_param(1, $host);
		$sth->bind_param(2, $history_limit);
		$sth->execute();
		$db_hsh = $sth->fetchall_hashref('ts');

		if($config->{prune_db} && !scalar keys %{$db_hsh}) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				$config->{_olddb} = $config->{db};
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
					$dbh = getdbh();
					$sth = $dbh->prepare("SELECT distinct id, ts, who FROM v_acked_history WHERE host = ? ORDER BY ts DESC LIMIT ?");
					$sth->bind_param(1, $host);
					$sth->bind_param(2, $history_limit);
					$sth->execute();
					$db_hsh = $sth->fetchall_hashref('ts');
					last if scalar keys %{$db_hsh};
				}
			} else {
				print "<p align=\"center\">I'm afraid, but your prune_db configuration is WRONG!</p>\n";
			}
		}

		if(scalar keys %{$db_hsh}) {
			$history_limit = scalar keys %{$db_hsh} if scalar keys %{$db_hsh} < $history_limit;
			print <<EOF;
			<center>
				<h2 $additional_h2_style>History data - latest $history_limit entries for $host (db: $config->{db}->{host})</h2>
				<table border="0" style="background-color:#BCB500; font-family:Courier,monospace; font-size:11px">
				<tr>
				<th width="380px" align="left">Timestamp</th>
				<th width="260px" align="left">Acknowledged by</th>
				</tr>
				<tr><td colspan="2"><hr></td></tr>
EOF
				foreach (sort keys %{$db_hsh}) {
					print "<tr><td>";
					print "<a href=\"?op=show_history_detail&history_id=$db_hsh->{$_}->{id}\">" if $db_hsh->{$_}->{id};
					print "$_";
					print "</a>" if $db_hsh->{$_}->{id};
					print "</td><td>$db_hsh->{$_}->{who}</td></tr>";
			}
			print <<EOF;
</table>
</center>
EOF
		} else {
			print "<p align=\"center\">No history data found</p>\n";
		}

		if($config->{_olddb}) {
			$config->{db} = $config->{_olddb};
			$dbh = getdbh();
		}

		# Query for the MD5s
		$sth = $dbh->prepare("SELECT checksum, file, status FROM checksums WHERE host = ? ORDER BY status DESC");
		$sth->bind_param(1, $host);
		$sth->execute();
		my $row = $sth->fetchrow_hashref();

		if($config->{prune_db} && !$row) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
					$dbh = getdbh();
					$sth = $dbh->prepare("SELECT checksum, file, status FROM checksums WHERE host = ? ORDER BY status DESC");
					$sth->bind_param(1, $host);
					$sth->execute();
					$row = $sth->fetchrow_hashref();
					last if $row;
				}
			} else {
				print "<p align=\"center\">I'm afraid, but your prune_db configuration is WRONG!</p>\n";
			}
		}
		if($row->{status} eq 'ok' && $mode eq 'short') {
			print "<center><h2 $additional_h2_style>No invalid MD5 sums for $host (db: $config->{db}->{host})</h2></center>";
			print end_html;
		}

		if($row) {
			print <<EOF;
<center>
<h2 $additional_h2_style>MD5 sums for $host (db: $config->{db}->{host})</h2>
<table border="0" style="background-color:#BCB500; font-family:Courier,monospace; font-size:11px">
<tr>
<th width="350px" align="left">File</th>
<th width="240px" align="left">Checksum</th>
<th width="50px" align="left">Status</th>
</tr>
<tr><td colspan="3"><hr></td></tr>
EOF
			while(1) {
				last if($row->{status} eq 'ok' && $mode eq 'short');
				my $color = 'green';
				$color = 'yellow' if $row->{status} ne 'ok';
				$color = 'red' if $row->{status} eq 'changed';
				print "<tr style=\"background-color:$color;\"><td>$row->{file}</td><td>$row->{checksum}</td><td>$row->{status}</td></tr>\n";
				last unless $row = $sth->fetchrow_hashref();
			}
			print <<EOF;
</table>
</center>
EOF
		} else {
			print "<p align=\"center\">No MD5 data found</p>\n";
		}

	} elsif(param('op') eq 'ack') {
		print header, start_html('MD5 sums acknowledgement');
		sub removemd5 {
			my $sth;

			# Check if this host is available on this database
			$sth = $dbh->prepare("SELECT count(*) AS count from checksums WHERE host = ? AND status != 'ok'");
			$sth->bind_param(1, $host);
			$sth->execute();
			my $res = $sth->fetchrow_arrayref();
			return if @{$res}[0] == 0; # Nothing here, so we get back to our caller, probably other db host

			# Add the history entry
			$sth = $dbh->prepare("INSERT INTO history (who) VALUES (?)");
			$sth->bind_param(1, $ENV{REMOTE_USER} || $ENV{AUTHENTICATED_UID} || 'Unknown');
			$sth->execute();
			my $id = $dbh->last_insert_id(undef, undef, 'history', 'id');

			$sth = $dbh->prepare("INSERT INTO acked_checksums (host, file, status, history_id) (
					SELECT ?, file, status, ?
					FROM checksums WHERE status != 'ok' and host = ?
			)");
			$sth->bind_param(1, $host);
			$sth->bind_param(2, $id);
			$sth->bind_param(3, $host);
			$sth->execute();

			# set all changed files to OK
			$sth = $dbh->prepare("UPDATE checksums SET status = 'ok', old_checksum = NULL WHERE host = ? AND status = 'changed'");
			$sth->bind_param(1, $host);
			$sth->execute();

			$sth = $dbh->prepare("UPDATE checksums SET status = 'ok' WHERE host = ? AND status = 'added'");
			$sth->bind_param(1, $host);
			$sth->execute();

			$sth = $dbh->prepare("DELETE FROM checksums WHERE host = ? AND status = 'removed'");
			$sth->bind_param(1, $host);
			$sth->execute();

			print "<p align=\"center\">Done on $config->{db}->{host}</p>\n";
		}
		# 'Local' database
		removemd5();

		# Remote databases (prune_db)
		if($config->{prune_db}) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
    				$dbh = getdbh();
					removemd5();
				}
			} else {
				print "<p align=\"center\">I'm afraid, but your prune_db configuration is WRONG!</p>\n";
			}
		}
		param(-name=>'op',-value=>'show');
		my $redir_url = self_url();
print <<EOF;
<script type="text/javascript">
<!--
  setTimeout(function(){window.location = "$redir_url"},3000);
//-->
</script>
EOF
	}
	print end_html;
}

1;

__END__

=head1 NAME

check_md5_by_ssh.pl

=head1 SYNOPSIS

    check_md5_by_ssh.pl -h <hostname or ip_address>

=head1 DESCRIPTION

Nagios script to check MD5 sums via SSH - database driven

The script also provides a web interface to show and acknowledge
MD5 sums. Eg. Someone installed/removed software packages or
updated the system.

=head1 DATABASE LAYOUT

CREATE TABLE checksums (
        host            varchar(256) DEFAULT NULL,
        checksum        varchar(130) DEFAULT NULL,
        old_checksum    varchar(130) DEFAULT NULL,
        file            varchar(2049) DEFAULT NULL,
        status          ENUM('ok', 'added', 'removed', 'changed') NOT NULL
);

CREATE TABLE history (
        id              int(11) NOT NULL AUTO_INCREMENT,
        ts              timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
        who             varchar(64) DEFAULT NULL,
        PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE acked_checksums (
	host		varchar(256) DEFAULT NULL,
	file		varchar(2049) DEFAULT NULL,
	status		enum('ok','added','removed','changed') NOT NULL,
	history_id	int(11) NOT NULL,
	KEY fk_history_id (history_id),
	CONSTRAINT fk_history_id FOREIGN KEY (history_id)
	REFERENCES history(id) ON DELETE CASCADE ON UPDATE NO ACTION
) ENGINE=InnoDB;

CREATE v_acked_history AS
	SELECT h.id, a.host, a.file, a.status, h.ts, h.who
	FROM history h, acked_checksums a
	WHERE a.history_id = h.id;

=head1 CONFIGURATION

=head2 OVERRIDING THE DEFAULTS

 Add the following content to a file called check_md5_by_ssh.yml
 if you need to override the defaults. Any values in the config file
 will override the defaults - so no need to copy the defaults, if you
 do not need to change them.

 check_by_ssh: /opt/omd/versions/1.00/lib/nagios/plugins/check_by_ssh
 ssh_user: root
 command: find /usr/bin/* /usr/sbin/* /sbin/* /bin/* /boot/* -maxdepth 1 -type f | xargs md5sum | sort
 ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
 check_by_ssh_opts: -E -t 180

 db:
   driver: DBI:mysql
   name: md5
   user: md5
   pass: checksums
   port: 
   host: localhost

 There is a very special configuration option for also removing the
 MD5s on a remote host. This is useful if you use distributed
 monitoring and want to allow your administrators to remotely wipe
 the entries. The configuration looks like this (of course, there
 is no default configuration for this):

 prune_db:
   remote_site:
     driver: DBI:mysql
     name: md5
     user: md5
     pass: checksums
     host: remote_host

 Note, that for remote sites you always have to provide _all_ database
 parameters, even if user/pass/database name might be the same as the
 local one.
 Yes, you can have several remote sites.
 
 Please be aware that in the current version, it will iterate over all
 remote sites and run the delete query. So if you have hosts with same
 ip addresses or hostnames (depending on your configuration), you'll
 delete all MD5s for all the hosts.

=head2 APACHE

 Add the following (or similar) alias to your apache configuration.
 In case you use OMD - this fits best in the 'site.conf'.

 ScriptAlias /test/ackmd5.pl /opt/nagios/plugins/check_md5_by_ssh.pl

=head2 NAGIOS / OMD

 Define a command (take care about the USER5 macro - this is probably
 different in your environment):

 define command {
   command_name    check_md5_by_ssh
   command_line    $USER5$/check_md5_by_ssh.pl --host $HOSTADDRESS$
 }

 Define a service for your hostgroup(s) (used in this example) or
 your host. Adjust for your needs.

 define service {
        use                     MYTEMPLATE
        hostgroup_name          unixlinux-group,solaris-group
        service_description     MD5
        check_command           check_md5_by_ssh
 }

 Define the extended service information, so you can delete the MD5s
 directly from within the Nagios interface (I suggest to use Thruk!).
 Note: You could also use the action URL, but usually it's used for PNP
 and the notes URL is usually free.

 define serviceextinfo{
        hostgroup_name          unixlinux-group,solaris-group
        service_description     MD5
        notes_url               /test/ackmd5.pl?op=ack&host=$HOSTADDRESS$
 }

 If you have a SSH check - like I have - you may consider adding a
 service dependency like the following:

 define servicedependency {
        hostgroup_name                  unixlinux-group,solaris-group
        service_description             SSH
        dependent_service_description   MD5
        notification_failure_criteria   w,c
 }

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2012-2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
