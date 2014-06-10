#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
Getopt::Long::Configure ('auto_version');
Getopt::Long::Configure ('auto_help');
use DBI;
use CGI qw/:standard -oldstyle_urls/;
use Sys::Hostname;
use Switch;
use YAML qw/LoadFile Load/;
use File::Spec;
use Hash::Merge qw/merge/;
Hash::Merge::set_behavior('RIGHT_PRECEDENT');
use Net::SSH2;
use IO::Scalar;
use Text::Diff;

# see pod for more information
my $defconfig = Load('
ssh_user: "root"
ssh_publickey: "/path/to/your/ssh-pub-key"
ssh_privatekey: "/path/to/you/ssh-priv-key"

db:
  driver: DBI:mysql
  name: filediff
  user: root
  pass:
  port:
  host: localhost
');

# This will not work on Windows. But we do not support Windows. :-P
my $configfile = File::Spec->catfile((File::Spec->splitpath(File::Spec->rel2abs($0)))[1], 'check_diff_by_ssh.yml');

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

# Our exit subroutine... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	print $mesg . "\n" if $mesg;
	exit ERRORS->{$code};
}

my $dbh = getdbh();

my ($host, $debug, @files);
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"files|f=s"	=> \@files,
	"debug|d"	=> \$debug,
);
if(@files) {
	$config->{files} = \@files;
}

$config->{command} = 'tar Pcf - ' . join(' ', @{$config->{files}});

# Command line mode 9-}
if($result && !param()) {
	do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;

	my $sth = $dbh->prepare("SELECT file, content, status, diff FROM files WHERE host = ?");
	$sth->bind_param(1, $host);
	$sth->execute();
	my $db_hsh = $sth->fetchall_hashref('file');
	my $fs_hsh;
	my ($added, $changed, $removed);
	
	my $ssh = Net::SSH2->new();
	$ssh->method('COMP_CS', 'zlib');
	$ssh->connect($host);
	
	$ssh->auth(username => $config->{ssh_user}, publickey => $config->{ssh_publickey}, privatekey => $config->{ssh_privatekey});
	if($ssh->auth_ok) {
		foreach my $file (@{$config->{files}}) {
			my $content;
			my $SH = new IO::Scalar \$content;
			$ssh->scp_get($file, $SH);
			close($SH);
			$fs_hsh->{$file} = $content;
		}
	} else {
		die "Unable to autenticate!";
	}

	# No run before - empty hash
	unless(keys %{$db_hsh}) {
		# Add all
		$dbh->begin_work;
		$sth = $dbh->prepare("INSERT INTO files (host, file, content, status) values (?, ?, ?, ?)");
		foreach(@{$config->{files}}) {
			my $stat = 'ok';
			$stat = 'unavailable' unless $fs_hsh->{$_};
			$sth->bind_param(1, $host);
			$sth->bind_param(2, $_);
			$sth->bind_param(3, $fs_hsh->{$_}||'');
			$sth->bind_param(4, $stat);
			$sth->execute();
		}
		$dbh->commit;
		do_exit('OK', 'Initial check was successful | files=' . (scalar keys %{$fs_hsh}) . ';;;changed=0;1;1;added=0;1;1;removed=0;1;1');
	} else {
		# Check for added or deleted files and changed files
		foreach(keys %{$fs_hsh}) {
			next unless $fs_hsh->{$_};
			# File existed before - no differences?
			if($db_hsh->{$_}) {
				my $diff = diff \$db_hsh->{$_}->{content}, \$fs_hsh->{$_}, { STYLE => 'Unified', };

				# Special case here. We already added this file as 'added' one.
				if($db_hsh->{$_}->{status} eq 'added') {
					$added->{$_} = {
						old	=> '',
						new	=> $fs_hsh->{$_},
						diff	=> '',
					};
				}

				# Changed (maybe again)
				if($diff) {
					# oops - content changed
					$changed->{$_} = {
						old	=> $db_hsh->{$_}->{content},
						new	=> $fs_hsh->{$_},
						diff	=> $diff,
					};
				# Changed (not again)
				} elsif($db_hsh->{$_}->{status} eq 'changed') {
					$changed->{$_} = {
						old	=> undef,
						new	=> $fs_hsh->{$_},
						diff	=> $db_hsh->{$_}->{diff},
					};
				}
			}
			if(!$db_hsh->{$_}) {
				# This has been added - exists in fs_hsh, but not yet in DB
				$added->{$_} = {
					old 	=> undef,
					new	=> $fs_hsh->{$_},
					diff	=> '',
				};
			}
		}
		# The other way round we just need to check if files have been removed.
		foreach(keys %{$db_hsh}) {
			# File still there? If not...
			if(!$fs_hsh->{$_}) {
				if($db_hsh->{$_}->{status} ne 'unavailable') {
					$removed->{$_} = {
						old	=> $db_hsh->{$_}->{content},
						new	=> undef,
						diff	=> '',
					};
				}
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
			$msg .= " + $_\n" foreach keys %{$added};
			my $added_query = 'INSERT INTO files (';
			# Add them to the database, but with the status 'added'
			# if not already done;
			$dbh->begin_work;
			$sth = $dbh->prepare("INSERT INTO files (host, file, status) values (?, ?, ?)");
			foreach(keys %{$added}) {
				next if $db_hsh->{$_}; # already in the database
				$sth->bind_param(1, $host);
				$sth->bind_param(2, $_);
				$sth->bind_param(3, 'added');
				$sth->execute();
			}
			$dbh->commit;
		}
		if($changed) {
			$msg .= "Changed files\n";
			$msg .= " ~ $_\n" foreach keys %{$changed};
			# Update status in the the database: 'changed'
			# if not already done
			$dbh->begin_work;
			$sth = $dbh->prepare("UPDATE files SET status = 'changed', content = ?, diff = ? WHERE host = ? AND file = ?");
			foreach(keys %{$changed}) {
				$sth->bind_param(1, $changed->{$_}->{'new'});
				$sth->bind_param(2, $changed->{$_}->{diff});
				$sth->bind_param(3, $host);
				$sth->bind_param(4, $_);
				$sth->execute();
			}
			$dbh->commit;
		}
		if($removed) {
			$msg .= "Removed files\n";
			$msg .= " - $_\n" foreach keys %{$removed};
			# Update status in the the database: 'removed'
			# if not already done
			$dbh->begin_work;
			$sth = $dbh->prepare("UPDATE files SET status = 'removed' WHERE host = ? AND file = ?");
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
		print header, start_html('Diff - error');
		print "<p align=\"center\">No host or history id given</p>\n";
		print end_html;
		exit 0;
	}
	if(param('op') eq 'show_history_detail') {
		print header, start_html('Diff - show history details');
		my($sth, $db_hsh);
		$sth = $dbh->prepare("SELECT host, file, status, ts, who, diff FROM v_acked_history WHERE id = ? ORDER BY status");
		$sth->bind_param(1, $history_id);
		$sth->execute();
		my $row = $sth->fetchrow_hashref();

		if($config->{prune_db} && !$row) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
					$dbh = getdbh();
					$sth = $dbh->prepare("SELECT host, file, status, ts, who, diff FROM v_acked_history WHERE id = ? ORDER BY status");
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
<th width="400px" align="left">Diff</th>
</tr>
<tr><td colspan="3"><hr></td></tr>
EOF
			while(1) {
				my $color = 'green';
				$color = 'yellow' if $row->{status} ne 'ok';
				$color = 'red' if $row->{status} eq 'changed';
				print "<tr style=\"background-color:$color;\">\n";
				print "<td>$row->{file}</td>\n";
				print "<td>$row->{status}</td>\n";
				print "<td><pre>$row->{diff}</pre></td>\n";
				print "</tr>\n";
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
		print header, start_html('Diff - show');
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

		# Query for the Diffs
		$sth = $dbh->prepare("SELECT file, status, diff FROM files WHERE host = ? ORDER BY status DESC");
		$sth->bind_param(1, $host);
		$sth->execute();
		my $row = $sth->fetchrow_hashref();

		if($config->{prune_db} && !$row) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
					$dbh = getdbh();
					$sth = $dbh->prepare("SELECT file, status, diff FROM files WHERE host = ? ORDER BY status DESC");
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
			print "<center><h2 $additional_h2_style>No diffs for $host (db: $config->{db}->{host})</h2></center>";
			print end_html;
		}

		if($row) {
			print <<EOF;
<center>
<h2 $additional_h2_style>Diffs for $host (db: $config->{db}->{host})</h2>
<table border="0" style="background-color:#BCB500; font-family:Courier,monospace; font-size:11px">
<tr>
<th width="350px" align="left">File</th>
<th width="240px" align="left">Diff (i/a)</th>
<th width="50px" align="left">Status</th>
</tr>
<tr><td colspan="3"><hr></td></tr>
EOF
			while(1) {
				last if($row->{status} eq 'ok' && $mode eq 'short');
				my $color = 'green';
				$color = 'yellow' if $row->{status} ne 'ok';
				$color = 'red' if $row->{status} eq 'changed';
				$row->{diff} = 'n/a' unless $row->{diff};
				print "<tr style=\"background-color:$color;\"><td>$row->{file}</td><td><pre>$row->{diff}</pre></td><td>$row->{status}</td></tr>\n";
				last unless $row = $sth->fetchrow_hashref();
			}
			print <<EOF;
</table>
</center>
EOF
		} else {
			print "<p align=\"center\">No diffs found</p>\n";
		}

	} elsif(param('op') eq 'ack') {
		print header, start_html('Diff acknowledgement');
		sub removediffs {
			my $sth;

			# Check if this host is available on this database
			$sth = $dbh->prepare("SELECT count(*) AS count from files WHERE host = ? AND status NOT IN ('ok', 'unavailable')");
			$sth->bind_param(1, $host);
			$sth->execute();
			my $res = $sth->fetchrow_arrayref();
			return if @{$res}[0] == 0; # Nothing here, so we get back to our caller, probably other db host

			# Add the history entry
			$sth = $dbh->prepare("INSERT INTO history (who) VALUES (?)");
			$sth->bind_param(1, $ENV{REMOTE_USER} || $ENV{AUTHENTICATED_UID} || 'Unknown');
			$sth->execute();
			my $id = $dbh->last_insert_id(undef, undef, 'history', 'id');

			$sth = $dbh->prepare("INSERT INTO acked_diffs (host, file, status, history_id, diff) (
					SELECT ?, file, status, ?, diff
					FROM files WHERE status NOT IN ('ok', 'unavailable') and host = ?
			)");
			$sth->bind_param(1, $host);
			$sth->bind_param(2, $id);
			$sth->bind_param(3, $host);
			$sth->execute();

			# set all changed files to OK
			$sth = $dbh->prepare("UPDATE files SET status = 'ok', diff = NULL WHERE host = ? AND status = 'changed'");
			$sth->bind_param(1, $host);
			$sth->execute();

			$sth = $dbh->prepare("UPDATE files SET status = 'ok' WHERE host = ? AND status = 'added'");
			$sth->bind_param(1, $host);
			$sth->execute();

			$sth = $dbh->prepare("DELETE FROM files WHERE host = ? AND status = 'removed'");
			$sth->bind_param(1, $host);
			$sth->execute();

			print "<p align=\"center\">Done on $config->{db}->{host}</p>\n";
		}
		# 'Local' database
		removediffs();

		# Remote databases (prune_db)
		if($config->{prune_db}) {
			# Catch some possible error
			if(ref $config->{prune_db} eq 'HASH') {
				foreach(keys %{$config->{prune_db}}) {
					$config->{db} = $config->{prune_db}->{$_};
    				$dbh = getdbh();
					removediffs();
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

check_diff_by_ssh.pl

=head1 SYNOPSIS

    check_diff_by_ssh.pl -h <hostname or ip_address>
                         [ -f /some/file ] [ -f /some/otherfile ] [ ...]

=head1 DESCRIPTION

    Nagios script to fetch files from an remote host via Net::SSH2 and check if
    it has changed. Mostly needed for configuration files.

    The script is based on my check_md5_by_ssh.pl script - you might want to
    check out this as well.

=head1 DATABASE LAYOUT

 CREATE TABLE files (
  file       VARCHAR(1024) DEFAULT NULL,
  content    TEXT,
  host       VARCHAR(256) DEFAULT NULL,
  status     ENUM('ok', 'added', 'removed', 'changed', 'unavailable') NOT NULL,
  diff       TEXT
 );

 CREATE TABLE history (
  id         INT(11) NOT NULL AUTO_INCREMENT,
  ts         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  who        VARCHAR(64) DEFAULT NULL,
  PRIMARY KEY (id)
 );

 CREATE TABLE acked_diffs (
  host       VARCHAR(256) DEFAULT NULL,
  file       VARCHAR(2049) DEFAULT NULL,
  status     ENUM('ok','added','removed','changed', 'unavailable') NOT NULL,
  diff       TEXT,
  history_id INT(11) NOT NULL,
  KEY fk_history_id (history_id),
  CONSTRAINT fk_history_id FOREIGN KEY (history_id)
  REFERENCES history(id) ON DELETE CASCADE ON UPDATE NO ACTION
 );

 CREATE VIEW v_acked_history AS
  SELECT h.id, a.host, a.file, a.status, a.diff, h.ts, h.who
  FROM history h, acked_diffs a
  WHERE a.history_id = h.id;


=head1 CONFIGURATION

=head2 OVERRIDING THE DEFAULTS

 Add the following content to a file called check_diff_by_ssh.yml
 if you need to override the defaults. Any values in the config file
 will override the defaults - so no need to copy the defaults, if you
 do not need to change them. However, you _NEED_ to adapt the paths
 to the ssh public/private key, since the defaults will definitely
 not work!

 ssh_user: "root"
 ssh_publickey: "/path/to/your/ssh-pub-key"
 ssh_privatekey: "/path/to/you/ssh-priv-key"

 files:
     - "/root/.ssh/authorized_keys"
     - "/etc/sudoers"

 db:
   driver: DBI:mysql
   name: filediff
   user: root
   pass:
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
     name: filediff
     user: filediff
     pass: somepass
     host: remote_host

 Note, that for remote sites you always have to provide _all_ database
 parameters, even if user/pass/database name might be the same as the
 local one.
 Yes, you can have several remote sites.

 Please be aware that in the current version, it will iterate over all
 remote sites and run the sql queries. So if you have hosts with same
 ip addresses or hostnames (depending on your configuration), you'll
 always affect all of them.

=head2 APACHE

 Add the following (or similar) alias to your apache configuration.
 In case you use OMD - this fits best in the 'site.conf'.

 /test/ackdiff.pl /opt/nagios/plugins/check_diff_by_ssh.pl


=head2 NAGIOS / OMD

 Define a command (take care about the USER5 macro - this is probably
 different in your environment):

 define command {
   command_name    check_diff_by_ssh
   command_line    $USER5$/check_diff_by_ssh.pl --host $HOSTADDRESS$ $ARG1$
 }

 Define a service for your hostgroup(s) (used in this example) or
 your host. Adjust for your needs.

 define service {
   use                     MYTEMPLATE
   hostgroup_name          unixlinux-group
   service_description     ConfigChanges
   check_command           check_diff_by_ssh
 }

 Define the extended service information, so you can acknowledge the
 changes directly from within the Nagios interface (I suggest to use Thruk!).
 Note: You could also use the action URL, but usually it's used for PNP
 and the notes URL is usually free.

 define serviceextinfo{
   hostgroup_name          unixlinux-group
   service_description     ConfigChanges
   notes_url               /test/ackdiff.pl?op=ack&host=$HOSTADDRESS$
 }

 If you have a SSH check - like I have - you may consider adding a
 service dependency like the following:

 define servicedependency {
   hostgroup_name                  unixlinux-group
   service_description             SSH
   dependent_service_description   ConfigChanges
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
