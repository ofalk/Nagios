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
check_by_ssh: /opt/omd/versions/default/lib/nagios/plugins/check_by_ssh
ssh_user: root
command: lsof 2>/dev/null|grep -E \'lib|bin\' |grep DEL|grep -v /SYSV00000000 | grep -v /var/lib/sss/mc | grep -v /etc/selinux/targeted/ | cut -f 1 -d \' \' | sort -u
ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
check_by_ssh_opts: -E -t 180
');

# This will not work on Windows. But we do not support Windows. :-P
my $configfile = File::Spec->catfile((File::Spec->splitpath(File::Spec->rel2abs($0)))[1], 'check_procs_need_restart_by_ssh.yml');

my $lclconfig = {};
$lclconfig = LoadFile($configfile) if -s $configfile;
my $config = merge($defconfig, $lclconfig);

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

my ($host, $debug);
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"debug|d"	=> \$debug,
);

# Command line mode 9-}
do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;

my $cmdline = $config->{check_by_ssh} . ' -H ' . " $host " . $config->{check_by_ssh_opts}. ' -l ' . $config->{ssh_user} . ' ' . $config->{ssh_opts} . ' -C "' . $config->{command} . '"';
print 'DEBUG: ' . $cmdline . "\n" if $debug;
open(FH, $cmdline . '|') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
my $nolines = 0;
my $output = "";
while(<FH>) {
	$output .= $_;
	$nolines++;
	chomp;
	my ($proc) = $_;
}
close(FH);
#print Dumper($fs_hsh) if $debug;

if($nolines < 2) {
	do_exit('OK', "No processes found that use outdated libraries/binaries! | processes=0");
} else {
	$nolines--;
	do_exit('WARNING', "Found $nolines processes using outdated libraries/binaries:\n$output | processes=$nolines;;;");
}

1;

__END__

=head1 NAME

check_procs_need_restart_by_ssh.pl

=head1 SYNOPSIS

    check_procs_need_restart_by_ssh.pl -h <hostname or ip_address>

=head1 DESCRIPTION

Nagios script to check number of processes that need to be restarted,
since they use libraries that have already been updated.

=head1 CONFIGURATION

=head2 OVERRIDING THE DEFAULTS

 Add the following content to a file called check_procs_need_restart_by_ssh..yml
 if you need to override the defaults. Any values in the config file
 will override the defaults - so no need to copy the defaults, if you
 do not need to change them.

 check_by_ssh: /opt/omd/versions/1.30/lib/nagios/plugins/check_by_ssh
 ssh_user: root
 command: lsof 2>/dev/null|grep lib |grep DEL|cut -f 1 -d " " | sort -u
 ssh_opts: -oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no
 check_by_ssh_opts: -E -t 180

=head2 NAGIOS / OMD

 Define a command (take care about the USER5 macro - this is probably
 different in your environment):

 define command {
   command_name    check_procs_need_restart_by_ssh
   command_line    $USER5$/check_procs_need_restart_by_ssh.pl --host $HOSTADDRESS$
 }

 Define a service for your hostgroup(s) (used in this example) or
 your host. Adjust for your needs.

 define service {
        use                     MYTEMPLATE
        hostgroup_name          unixlinux-group
        service_description     ProcRestarts
        check_command           check_procs_need_restart_by_ssh
 }

 If you have a SSH check - like I have - you may consider adding a
 service dependency like the following:

 define servicedependency {
        hostgroup_name                  unixlinux-group
        service_description             SSH
        dependent_service_description   ProcRestarts
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
