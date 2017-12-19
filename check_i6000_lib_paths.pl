#!/usr/bin/perl

use strict;
use warnings;

use Getopt::Long;
Getopt::Long::Configure ('auto_version');
Getopt::Long::Configure ('auto_help');
use DBI;
use CGI qw/:standard/;
use Sys::Hostname;
use Switch;

# You might want to change this constants to reflect your setup
use constant CHECK_BY_SSH	=> '/opt/omd/versions/default/lib/nagios/plugins/check_by_ssh';
use constant USER		=> 'root';
use constant SSH_OPTS		=> '-oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no';

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
	print $mesg if $mesg;
	print "\n";
	exit ERRORS->{$code};
}

my $OPTS = '-E -t 120';

my $host;
my $dz;
my $site;
my $num_paths;
my $lib = 0;
my $notcrit;
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"dz=i"		=> \$dz,
	"site=s"	=> \$site,
	"num_paths=i"	=> \$num_paths,
	"lib"		=> \$lib,
	"notcrit"	=> \$notcrit,
);

if($lib && !$num_paths) {
	$num_paths = 1;
}

# Command line mode 9-}
do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;
do_exit('CRITICAL', 'No datazone given (use --dz)') unless $dz;
do_exit('CRITICAL', 'No site given (use --site)') unless defined $site;
do_exit('CRITICAL', 'No number of paths given (use --num_paths)') unless $num_paths;

my $COMMAND;
my $scmd = '';
$scmd = "_$site" if $site;
unless($lib) {
	$COMMAND = "ls -1 /dev/tape/by-id/i6000$scmd" . "_dz$dz" . "_drv* | wc -l";
} else {
	$COMMAND = "ls -1 /dev/tape/by-id/i6000$scmd" . "_dz$dz | wc -l";
}

open(FH, CHECK_BY_SSH . ' -H ' . " $host  $OPTS " . '-l ' . USER . ' ' . SSH_OPTS . ' -C "' . $COMMAND . '" |') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
my $dev_count = <FH>;
chomp($dev_count);
close(FH);
if($dev_count != $num_paths) {
	my $state = 'CRITICAL';
	$state = 'WARNING' if $notcrit;
	do_exit($state, "$state: Number of paths doesn't match: WANTED: $num_paths, GOT: $dev_count");
} else {
	do_exit('OK', "OK: Number of available paths ($dev_count) matches");
}

1;

__END__

=head1 NAME

check_i6000_lib_paths.pl

=head1 SYNOPSIS

    # For drives /dev/tape/by-id/i6000_flo_dz1_drv* - 6 must be there in this case:
    check_i6000_lib_paths.pl -h <hostname> --dz 1 --site flo --numpaths 6

    # For library /dev/tape/by-id/i6000_flo_dz1 - 1 must be there:
    check_i6000_lib_paths.pl -h <hostname> --dz 1 --site flo --lib

    # If you don't want CRITICAL, add --notcrit

=head1 DESCRIPTION

Nagios Script to check available paths for some i6000 library

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2012-2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
