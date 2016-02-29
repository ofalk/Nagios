#!/usr/bin/perl

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2014
# Original script by Richard Kästner <richard.kaestner@kabsi.at>

use strict;
use warnings;

use Net::DNS;
use Getopt::Long;
Getopt::Long::Configure ('auto_version');
Getopt::Long::Configure ('auto_help');
use Data::Dumper; # For debugging

my $debug = 0;
my $msg = '';
my $overallstatus = 'OK';

# Nagios status codes
use constant ERRORS => {
	UNKNOWN		=> -1,
	OK		=> 0,
	WARNING		=> 1,
	CRITICAL	=> 2,
};

# Our exit subroutine... Just because it's handy
sub do_exit {
	my $code = shift;
	my $mesg = shift;
	print $mesg if $mesg;
	exit ERRORS->{$code};
}

sub _resolv($) {
	my $q = shift;
	my $res = new Net::DNS::Resolver;

	my $query = $res->search($q);
	if($query) {
		my $ret;
		foreach ($query->answer()) {
			if($_->type() eq 'A') {
				push @{$ret->{$_->type()}}, { address => $_->address(), name => $_->name() };
			} elsif ($_->type eq 'CNAME') {
				push @{$ret->{$_->type()}}, { name => $_->cname(), cname => $_->name() };
			} elsif ($_->type eq 'PTR') {
				if ($_->ptrdname !~ /.*in-addr.arpa/i) {
					push @{$ret->{$_->type()}}, { ptrdname => $_->ptrdname() };
				} else {
					# what!?
				}
			} else {
				print "Received '" . $_->type() . "' as an answer, while querying for '$q'" if $debug;
			}
		}
		$ret;
	} else {
		{};
		#do_exit('CRITICAL', "CRITICAL: Unable to query for '$q': " . $res->errorstring . "\n");
	}
}

sub _check_qaddr_res_addr($$) {
	my $qname = shift;
	my $qaddr = shift;
	my $status = 'CRITICAL';
	my @addr;
	# $qaddr = resolved addr (from $qname)
	foreach(@{_resolv($qname)->{A}}) {
		print "DEBUG_1: Check $_->{address} == $qaddr\n" if $debug;
		if($_->{address} eq $qaddr) {
			$status = 'OK';
		}
		push @addr, $_->{address};
	}
	if($status ne 'OK' && @addr) {
		$msg .= "$status: $qaddr (queried address) not in " . join(',', @addr) . " (resolved addresse(s))\n";
		$overallstatus = $status;
	} elsif($status ne 'OK' && !@addr) {
		$msg .= "$status: $qname seems to be unresolvable!\n";
		$overallstatus = $status;
	}
	return @addr;
}

sub _check_qname_res_name($) {
	my $qname = shift;
	my $status = 'CRITICAL';
	my @names;
	my @qn;
	# $qname = resolved name (from $qname)

	# Handle cases of CNAMEs correctly, since the PTR will/should/must
	# point back to the real IP, instead of the CNAME record - of course.
	my $re = _resolv($qname);
	if($re->{CNAME}) {
		foreach(@{$re->{CNAME}}) {
			push @qn, $_->{name};
		}
	} else {
		@qn = ($qname);
	}
	foreach $qname (@qn) {
		foreach(@{$re->{A}}) {
			print "DEBUG_2: Check $_->{name} =~ $qname\n" if $debug;
			if($_->{CNAME}) {
				$qname = $_->{CNAME};
				$qname =~ s/^(.*){1}\./$1/;
			}
			if(($_->{name} =~ /^$qname\./i) || ($_->{name} eq $qname)) {
				$status = 'OK';
			}
			push @names, $_->{name};
		}
		if($status ne 'OK') {
			if(@names) {
				$msg .= "$status: $qname (queried name) not in " . join(', ', @names) . " (resolved name(s))\n";
			} else {
				$msg .= "$status: $qname (queried name) doesn't resolve to anything!\n";
			}
			$overallstatus = $status;
		}
	}
	return @names;
}

sub _check_ptrs_resolve(@) {
	my $addr = shift;
	my @addr = @{$addr};

	my $status = 'CRITICAL';
	my $anyresolvable = 0;
	foreach my $a (@addr) {
		my $rev = _resolv($a);
		if(scalar keys %{$rev}) {
			$anyresolvable = 1;
		} else {
			print "DEBUG_3: $a doesn't resolve - ignore!\n";
		}
	}
	unless($anyresolvable) {
		$overallstatus = 'CRITICAL';
		$status = 'CRITICAL';
		$msg .= "CRITICAL: None of the PTR records (" . join(',', @addr) . ") resolves back to anything!!!\n";
	}
}

my ($qname, $qaddr);

my $result = GetOptions(
	"name|n=s"		=> \$qname,
	"address|addr|a=s"	=> \$qaddr,
	"debug|d"		=> \$debug,
);

do_exit('CRITICAL', "CRITICAL: No name (-n) and/or address (-a) given!\n") unless ($qname || $qaddr);

if($qname) {
	my $rn = _resolv($qname);
	print Dumper($rn) if $debug;
};
if($qaddr) {
	my $rn = _resolv($qaddr);
	print Dumper($rn) if $debug;
};

if($qname && $qaddr) {
	my @addr = _check_qaddr_res_addr($qname, $qaddr);

	if(@addr) {
		_check_ptrs_resolve(\@addr);
		my @names = _check_qname_res_name($qname);
	}
} elsif($qname && !$qaddr) {
	my @names = _check_qname_res_name($qname);
	if(scalar @names) {
		$qaddr = (_resolv($qname))->{A}[0]->{address};
		my @addr = _check_qaddr_res_addr($qname, $qaddr);
	}
} elsif($qaddr && !$qname) {
	$qname = (_resolv($qaddr))->{PTR}[0]->{ptrdname};
	if($qname) {
		my @names = _check_qname_res_name($qname);
		my @addr = _check_qaddr_res_addr($qname, $qaddr);
	} else {
		$overallstatus = 'CRITICAL';
		$msg .= "CRITICAL: $qaddr doesn't resolve to anything!\n";
	}
}

do_exit($overallstatus, $msg||"Everything OK ($qname <=> $qaddr maps correctly back and forth)!\n");
