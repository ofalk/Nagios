#!/usr/bin/perl

use strict;
use warnings;

use Socket;
use Getopt::Long;
Getopt::Long::Configure ('auto_version');
Getopt::Long::Configure ('auto_help');
use File::Spec;
use Data::Dumper;
use YAML qw/LoadFile Load/;
use Hash::Merge qw/merge/;
Hash::Merge::set_behavior('RIGHT_PRECEDENT');

use constant ERRORS => {
	OK		=> 0,
	WARNING		=> 1,
	CRITICAL	=> 2,
	UNKNOWN		=> 3,
};

# see pod (TODO) for more information
my $defconfig = Load('
checks:
exceptions:
');


my $host = '127.0.0.1';
my $configfile = $0;
$configfile =~ s/\.pl$//;
$configfile .= '.yml';
my $debug = 0;

my $result = GetOptions(
	"host|h|H=s"		=> \$host,
	"configfile|c=s"	=> \$configfile,
	"debug|d=i"		=> \$debug,
);

$configfile = File::Spec->rel2abs($configfile);

my $lclconfig = {};
$lclconfig = LoadFile($configfile) if -s $configfile;
my $config = merge($defconfig, $lclconfig);

my $errors;
my $ok;
my $maxsrvchars = 0;

foreach(keys %{$config->{checks}}) {
	$maxsrvchars = length($_) if length($_) > $maxsrvchars;
	my $port = $_;
	my $proto = 'tcp';
	unless(keys %{$config->{checks}->{$_}}) {
		if ($port =~ /\D/) { $port = getservbyname($port, $proto) }
	} else {
		$proto = $config->{checks}->{$_}->{proto} || $proto;
		$port = $config->{checks}->{$_}->{port} || $port;
		if ($port =~ /\D/) { $port = getservbyname($port, $proto) }
	}
	unless($port && $proto) {
		$errors->{$_} = 'Could not resolve port and/or protocol';
		next;
	}

	my $iaddr = inet_aton($host);
	unless($iaddr) {
		$errors->{$_} = "Could not resolv host ('$host')";
		next;
	}

	warn "Checking $_ ($port)" if $debug;
	$proto  = getprotobyname("tcp");
	my $paddr   = sockaddr_in($port, $iaddr);
	my $con;
	eval {
		local $SIG{ALRM} = sub { die 'Timed Out'; }; 
		alarm 1;
		socket(SOCK, PF_INET, SOCK_STREAM, $proto)  || die "socket: $!";
		$con = connect(SOCK, $paddr);
		alarm 0;
	};
	alarm 0;
	unless($con) {
		$ok->{$_} = 'Seems to be closed!';
	} else {
		unless($config->{exceptions}->{$host}->{$_}) {
			$errors->{$_} = 'Seems to be open!';
		} else {
			$ok->{$_} = 'Seems to be open but an exception exists!';
		}
	}
	undef $con;
}

my $exitstate = ERRORS->{OK};

print Dumper($errors, $ok) if $debug > 1;

if(keys %{$errors}) {
	printf("CRITICAL - %i services found\n", scalar keys %{$errors});
	printf(" - %*s: " . $errors->{$_} . "\n", $maxsrvchars, $_) foreach (keys %{$errors});
	print "\n";
	$exitstate = ERRORS->{CRITICAL};
}
if(keys %{$ok}) {
	printf("OK - %i services found\n", scalar keys %{$ok});
	printf(" - %*s: " . $ok->{$_} . "\n", $maxsrvchars, $_) foreach (keys %{$ok});
	print "\n";
}

exit $exitstate;
