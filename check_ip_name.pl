#!/usr/bin/perl -w

# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2012-2013
#               and Richard Kästner <richard.kaestner@kabsi.at>

use Socket;
use Getopt::Std;
use Net::DNS;
use Data::Dumper;

use strict;
my $res   = Net::DNS::Resolver->new;
my $query;

my $Address = "10.200.20.12";
my $s1 = "";

my ( $QueryString, $QueryAddress);
my ( $DBG, $DbgOut, $DbgOutDumper);
$DBG = 0;

my %Result = (
  'PARAM'   => {
  },
  'CNAME'   => {
    'name'    => '',
    'cname'   => '',
    'count'   => 0,
  },
  'A'       => {
    'address' => '',
    'name'    => '',
    'count'   => 0,
  },
  'PTR'     => {
    'ptrdname' => '',
    'count'   => 0,
  },
);

# $query = $res->search("host.example.com");
#
# DNS Entry: 
#   FQDN  = "accounting2.rfk.priv"
#   CNAME = "acc2.rfk.priv"
#   A     = "10.200.20.11"
# A - records
#  $QueryString = "accounting2.rfk.priv";
#  $QueryString = "accounting2";
# CNAME - records
#  $QueryString = "acc2.rfk.priv";
#  $QueryString = "acc2";
# PTR -records
#   $QueryString = "10.200.20.12";
#
# Domain:
#   $QueryString = "richardkaestner.com";

sub doResolve {
  $QueryString = shift;
  
  $query = $res->search("$QueryString");
  if ($query) {
    $DbgOut       .= "\n*** Lookup by Name ***\n\nQueryString     : '$QueryString'\n";
    $DbgOutDumper .= "";
    foreach my $rr ($query->answer) {
      # Types: CNAME , PTR , A
      $DbgOutDumper .= "*** Type: '" . $rr->type . "' ***\n";
      $DbgOutDumper .= Dumper(\$rr) ;
      $DbgOutDumper .= "\n--------------\n";
      # case:
      #   TYPE = A     --> $rr->address = IP
      #   TYPE = CNAME --> $rr->cname = FQDN , look for 'A' record !
      #
      #   TYPE = PTR   --> 
      #
      if ( $rr->type eq "A" ) {
        $s1 = $rr->address;
        $Result{'A'}{'address'} .= "$s1:";
        $s1 = $rr->name;
        $Result{'A'}{'name'} .= "$s1:";
        $Result{'A'}{'count'} += 1;
      }
      if ( $rr->type eq "CNAME" ) {
        $s1 = $rr->cname;
        $Result{'CNAME'}{'name'} .= "$s1:";
        $s1 = $rr->name;
        $Result{'CNAME'}{'cname'} .= "$s1:";
        $Result{'CNAME'}{'count'} += 1;
      }
      if ( $rr->type eq "PTR" )   {
        if ( $rr->ptrdname !~ /.*in-addr.arpa/i ) {
          $s1 = $rr->ptrdname;
          $Result{'PTR'}{'ptrdname'} .= "$s1:";
          $Result{'PTR'}{'count'} += 1;
        }
      }
    }
  } else {
    warn "query failed: ", $res->errorstring, "\n";
  }

} # doResolve

sub usage {
  print STDERR "Usage:\n    $0   -n <hostname> -a <address>\n";
}


sub GetNameFromAddress {
  my $Address      = shift;
  my ( $n_addr, $name_from_addr);
  $n_addr          = inet_aton($Address);  
  if ( ! defined($n_addr) ) {
    $name_from_addr  = 'IP-DOESNT-RESOLV';
  } else {
    $name_from_addr  = gethostbyaddr($n_addr, AF_INET);
    $name_from_addr  =~ /(.*?)\./i;
    $name_from_addr  = $1;     # strip domain
    $name_from_addr  =~ s/\r//g;
    chomp $name_from_addr;
  }
  return  $name_from_addr;
} # GetNameFromAddress




my %options=(
  'a' => 'ADDR_UNDEF',
  'n' => 'NAME_UNDEF',
  'd' => 0,
);
getopts("a:n:d", \%options);

if ( (! defined($options{'a'} ) ) || ( $options{'a'} =~ /^$/) ) { $options{'a'} = 'ADDR_UNDEF'; }
if ( (! defined($options{'n'} ) ) || ( $options{'n'} =~ /^$/) ) { $options{'n'} = 'NAME_UNDEF'; }
if ( defined($options{'d'} ) && $options{'d'} > 0 ) { $DBG = 1; }

$options{'a'} = lc($options{'a'});
$options{'n'} = lc($options{'n'});

# neither parameter given: CRITICAL
if ( ( (!defined($options{'a'}) ) && (! defined($options{'n'}) ) )
     || (   ($options{'a'} =~ /UNDEF/) && ($options{'n'} =~ /UNDEF/) ) 
   ) {
  usage();
  exit 2;
}

$Result{'PARAM'}{'name'}    = $options{'n'};
$Result{'PARAM'}{'address'} = $options{'a'};
$DbgOut = "";
$DbgOutDumper = "";
# ------------------ now name lookup / resolve: ------------------
doResolve $Result{'PARAM'}{'name'};

# ------------------ now reverse lookup / resolve: ------------------
doResolve $Result{'PARAM'}{'address'};

# ------------------ Result compare and Output ----------------
# cleanup the trailing ":" (-> list handling)
$Result{'PTR'}{'ptrdname'} =~ s/:$//g;
$Result{'A'}{'name'} =~ s/:$//g;
$Result{'A'}{'address'} =~ s/:$//g;
$Result{'CNAME'}{'name'} =~ s/:$//g;
$Result{'CNAME'}{'cname'} =~ s/:$//g;
# $Result{''}{''} =~ s/:$//g;

# Calculate result:
#     Names: (may be FQD, Short Name or Aliases)
#       $SearchName = $Result{'PARAM'}{'name'} 
#     must match:
#       - one of $Result{'PTR'}{'ptrdname'}    (may be a list !)
# and
#     Address:
#       $SearchAddress = $Result{'PARAM'}{'address'} 
#     must match:
#       $Result{'A'}{'address'}
#
# Resultcode
#   both match:   OK
#   one or none match: CRITICAL

if ( $DBG ) { print STDERR Dumper(\%Result); }

my $SearchName    = $Result{'PARAM'}{'name'};
my $SearchAddress = $Result{'PARAM'}{'address'};

if ( 
  ($Result{'PTR'}{'ptrdname'} =~ /$SearchName\.?.*?/i)
  && ($Result{'A'}{'address'} =~ /$SearchAddress/i)
) {
  print "OK: DNS matches\n";
  exit 0;
} 

print "CRITICAL RESOLVE ERROR: $SearchName => '" . $Result{'A'}{'address'} . "'\n"
  . " BUT $SearchAddress => '" . $Result{'PTR'}{'ptrdname'} . "'\n";
exit 2;

exit ;


__END__
