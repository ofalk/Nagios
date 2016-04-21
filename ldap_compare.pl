#!/usr/bin/env perl 
#===============================================================================
#
#         FILE: ldap_compare.pl
#
#        USAGE: ./ldap_compare.pl  
#
#  DESCRIPTION: This little script dumps ldap data and compares it to the latest
#               known version (saved with Cache::File).
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Oliver Falk <oliver@linux-kernel.at> or <oliver.falk@omv.com>
# ORGANIZATION: Linux Kernel Austria / EOF Media Consult / OMV
#      VERSION: 1.0
#      CREATED: 04/04/2016 01:15:40 PM
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use utf8;

use Net::LDAP;
use Net::LDAP::Control::Paged;
use Net::LDAP::Constant qw( LDAP_CONTROL_PAGED );
use Getopt::Long;

use Cache::File;
use FreezeThaw qw/safeFreeze thaw/;
use Text::Diff qw/diff/;

use constant ERRORS => { "OK" => 0, "WARNING" => 1, "CRITICAL" => 2, "UNKNOWN" => 3 };

my $ldap_server = '';
my $ldap_base   = 'dc=myorg,dc=com';
my $ldap_login  = 'cn=admin' . $ldap_base;
my $ldap_secret = '/etc/ldap.secret';
my $ldap_pw;
my $ldap_filter = '(objectclass=*)';
my @attrs;

my $res = GetOptions(
	'host|h=s'     => \$ldap_server,
	'base|b=s'     => \$ldap_base,
    'login|D=s'    => \$ldap_login,
    'secret|s=s'   => \$ldap_secret,
    'password|w=s' => \$ldap_pw,
	'filter|f=s'   => \$ldap_filter,
	'attrs|a=s'    => \@attrs,
);

my $cache = Cache::File->new(
    cache_root      => '/var/tmp/ldap.cache',
	default_expires => '2 days',
);
my $cache_key = $ldap_server . $ldap_base . $ldap_login . $ldap_secret . $ldap_filter . join(',', @attrs);


die "No ldap server given" unless $ldap_server;

# Define variables before using it
my ($ldap, $msg);

if (-f $ldap_secret && ! $ldap_pw) {
        open(my $fh, $ldap_secret) || die "Cannot read " . $ldap_secret;
        $ldap_pw = <$fh>;
        chomp($ldap_pw);
        close $fh;
}

die "No ldap password given" unless defined $ldap_pw;

$ldap = Net::LDAP->new(
	$ldap_server,
	onerror => 'warn',
);
if($@) {
	warn "Connection error: $@";
	exit ERRORS->{'UNKNOWN'};
}

my $page = Net::LDAP::Control::Paged->new( size => 100 );
$msg = $ldap->bind($ldap_login, password => $ldap_pw);
if($msg->code) {
	warn "Cannot check, problem binding: " . $msg->error;
	exit ERRORS->{'UNKNOWN'};
}

my @args = (
	base     => $ldap_base,
	filter   => $ldap_filter,
	attrs    => [ @attrs ],
	control  => [ $page ],
);

#use Data::Dumper; warn Dumper(@args);

my ($new_cust, $old_cust);
my $cookie;
while(1) {
	$msg = $ldap->search(@args);

	# Only continue on LDAP_SUCCESS
	$msg->code && die $msg->error;

	for (my $i = 0; $i < $msg->count; $i++) {
		#print "dn: " . $msg->entry($i)->dn . "\n";
		foreach my $attr ($msg->entry($i)->attributes) {
		    #print "$attr: $_\n" foreach($msg->entry($i)->get_value($attr));
			push @{$new_cust->{$msg->entry($i)->dn}}, "$attr: $_" foreach($msg->entry($i)->get_value($attr));
		}
		#print "\n";
	}
    # Get cookie from paged control
    my ($resp) = $msg->control(LDAP_CONTROL_PAGED) or last;
    $cookie = $resp->cookie or last;
    # Set cookie in paged control
    $page->cookie($cookie);
}

if($cookie) {
        # We had an abnormal exit, so let the server know we do not want any more
        $page->cookie($cookie);
        $page->size(0);
        $ldap->search(@args);
		exit ERRORS->{'UNKNOWN'};
}

eval { $old_cust = ${\thaw($cache->get($cache_key))} };
$cache->set($cache_key, safeFreeze($new_cust));

#use Data::Dumper; warn Dumper($new_cust);
#use Data::Dumper; warn Dumper($old_cust);

#### Compare old and new
my $seen_dn;
my $to_print = '';
foreach my $dn (keys %{$new_cust}) {
    $seen_dn->{$dn} = 1;
    if($old_cust->{$dn}) {
        #print "$dn is available in both old and new dump\n";
        my $new_entry = '';
        my $old_entry = '';
        $new_entry .= "$_\n" foreach(@{$new_cust->{$dn}});
        $old_entry .= "$_\n" foreach(@{$old_cust->{$dn}});
        my $diff = diff \$old_entry, \$new_entry, { STYLE => 'Table' };
        if($diff) {
			$to_print .= "Changes to $dn:\n$diff";
            $to_print .= "$dn:\n" . $new_entry . "\n";
        }
    } else {
		$to_print .= "$dn has been added:\n";
		$to_print .= " - $_\n" foreach @{$new_cust->{$dn}};
		$to_print .= "\n";
    }
}

foreach my $dn (keys %{$old_cust}) {
    next if $seen_dn->{$dn};
    $to_print .= "$dn has been removed:\n";
    $to_print .= "$_\n" foreach @{$old_cust->{$dn}};
}

if($to_print) {
	print $to_print ."\n";
	exit ERRORS->{'CRITICAL'};
} else {
	print "No modifications found!\n";
	exit ERRORS->{'OK'};
}
