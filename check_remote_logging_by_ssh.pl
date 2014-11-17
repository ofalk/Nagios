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

my ($host, $expected);
my $grep = '^\*\.\*.*@';
my $file = '/etc/*syslog*conf';
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"grep|g=s"	=> \$grep,
	"file|f=s"	=> \$file,
	"expected|e=s"	=> \$expected,
);

do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;
do_exit('CRITICAL', 'No expected string given (use --expected/-e)') unless $expected;

my $found = 0;
my $matches = 0;
my $output;
my $command = "grep '$grep' $file";

open(FH, CHECK_BY_SSH . ' -H ' . " $host  $OPTS " . '-l ' . USER . ' ' . SSH_OPTS . ' -C "' . $command . '" |') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
while(<FH>) {
	$found += 1 if /$expected/;
	$matches++;
	$output .= $_;
}
close(FH);

if($found) {
	if($found > 1) {
		do_exit('WARNING', "WARNING: Found more than one line matching ($expected) in the output:\n$output");
	} else {
		if($matches > 1) {
			do_exit('WARNING', "WARNING: Found the expected string ($expected), but additional strings as well:\n$output");
		} else {
			do_exit('OK', "OK: Found the expected string ($expected) in the output:\n$output");
		}
	}
} else {
	do_exit('CRITICAL', "CRITICAL: Didn't find the expected string ($expected) in the output:\n$output");
}

1;

__END__

=head1 NAME

check_remote_logging_by_ssh.pl

=head1 SYNOPSIS

    check_remote_logging_by_ssh.pl.pl -h <hostname> -e <expected string> -g <grep_regex> -f <remote_file>

=head1 DESCRIPTION

Nagios Script to check if remote logging has been correctly configured

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
