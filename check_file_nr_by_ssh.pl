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
use constant CHECK_BY_SSH	=> "/opt/omd/versions/1.10/lib/nagios/plugins/check_by_ssh";
use constant USER		=> 'root';
use constant COMMAND		=> 'cat /proc/sys/fs/file-nr';
use constant SSH_OPTS		=> '-oNumberOfPasswordPrompts=0 -oPasswordAuthentication=no -oStrictHostKeyChecking=no';

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
	print $mesg if $mesg;
	exit ERRORS->{$code};
}

my $OPTS = '-E -t 120';

my $warn = 90;
my $crit = 95;
my $host;
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"warn|w=i"	=> \$warn,
	"crit|w=i"	=> \$crit,
);

do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;
do_exit('CRITICAL', 'Warning level must be lower than critical level!') if $warn >= $crit;

my $output;

open(FH, CHECK_BY_SSH . ' -H ' . " $host  $OPTS " . '-l ' . USER . ' ' . SSH_OPTS . ' -C "' . COMMAND . '" |') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
while(<FH>) {
	$output .= $_;
}
close(FH);
my ($alloc, $free, $max) = split(/\s+/,$output);

my $percent_used = $alloc / ($max/100);

my $perfdata = sprintf("used=%.2f%%;$warn;$crit;; alloc=$alloc;;;;\n", $percent_used);

do_exit('CRITICAL', "CRITICAL: Used file handles > $crit ($alloc / $max) | $perfdata") if $percent_used >  $crit;
do_exit('WARNING', "WARNING: Used file handles > $warn ($alloc / $max) | $perfdata") if $percent_used > $warn;
do_exit('OK', "OK: Used file handles is OK ($alloc / $max) | $perfdata");

1;

__END__

=head1 NAME

check_file_nr_by_ssh.pl

=head1 SYNOPSIS

    check_file_nr_by_ssh.pl -h <hostname> [ -w <warn> ] [ -c <crit> ]

    critical default => 95
    warning default => 90

=head1 DESCRIPTION

Nagios ccript to check if machine runs out of file handles

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2012-2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
