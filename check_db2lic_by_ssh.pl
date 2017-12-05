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

# Our exit subrouting... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	print $mesg if $mesg;
	exit ERRORS->{$code};
}

my $OPTS = '-E -t 120';

my ($host, $user, $product);
Getopt::Long::Configure ('pass_through');
my $result = GetOptions (
	"host|h=s"	=> \$host,
	"user|u=s"	=> \$user,
	"product|p=s"	=> \$product,
);

my $COMMAND = "su - $user -c 'db2licm -l'";

do_exit('CRITICAL', 'No host given (use --host/-h)') unless $host;
do_exit('CRITICAL', 'No user given (use --user/-u)') unless $user;
do_exit('CRITICAL', 'No product string given (use --product/-p)') unless $product;

my $found = 0;
my $output;

open(FH, CHECK_BY_SSH . ' -H ' . " $host  $OPTS " . '-l ' . USER . ' ' . SSH_OPTS . ' -C "' . $COMMAND . '" |') or do_exit('UNKNOWN', "Remote command execution on '$host' failed");
my $licinf;
my $curprod;
while(<FH>) {
	$output .= $_;
	m/^(.*):\s+"(.*)"$/;
	my $key = $1;
	my $value = $2;
	next unless $key;
	next unless $value;
	if($key eq 'Product name') {
		$curprod = $value;
		# Product name transformation to make sure we also catch Advanced servers :-/
		$curprod =~ s/DB2 Advanced Enterprise Server Edition/DB2 Enterprise Server Edition/;
		next;
	}
	if($curprod) {
		$licinf->{$curprod}->{$key} = $value;
	}
}
close(FH);
#use Data::Dumper;
#warn Dumper($licinf);

do_exit('UNKNOWN', "CRITICAL: No output. SSH works!?!?") unless $output;
do_exit('UNKNOWN', "CRITICAL: Unparsable output or product not found:\n$output") unless $licinf->{$product};
if($licinf->{$product}->{'Expiry date'} eq 'Permanent') {
	do_exit('OK', "OK: Expiry date 'Permanent' found in the output (for Product '$product'):\n$output");
} elsif ($licinf->{$product}->{'License type'} eq 'Trial') {
	do_exit('CRITICAL', "CRITICAL: License only Trial and will expire on " . $licinf->{$product}->{'Expiry date'} . " for Product ('$product'):\n$output");
} else {
	do_exit('UNKNOWN', "CRITICAL: Unable to determine license status from output:\n$output");
}

1;

__END__

=head1 NAME

check_db2lic_by_ssh.pl

=head1 SYNOPSIS

    check_db2lic_by_ssh.pl -h <hostname> -e <expected string>

=head1 DESCRIPTION

Nagios Script to check the license status of some DB2 installation via SSH.

=head1 AUTHOR

Oliver Falk <oliver@linux-kernel.at>

=head1 COPYRIGHT

Copyright (c) 2013-2014. Oliver Falk. All rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
