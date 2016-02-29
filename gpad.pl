#!/usr/bin/perl
#
# G.P.A.D. = General Purpose Ajax Dispatcher
# XML::RPC on steroids 8-Q
#
# This was an idea to ease the development of small sites
# with AJAX. Very low usage at the moment, but maybe someone
# has interest in it.
#
# Copyright (c) by Oliver Falk <oliver@linux-kernel.at>, 2014

use strict;
use warnings;

use CGI qw/:standard/;

use FindBin;
use lib $FindBin::Bin . '/perl-lib';
use lib '/omd/sites/test/perl-lib/';
use lib '/omd/versions/1.10/lib/perl5/lib/perl5/';

use Template;

my $q = new CGI;
my $ajaxlet = param('ajaxlet');
my $request = param('request');

die "ERROR: Unable to process this request" unless ($ajaxlet && $request);

my $template = Template->new({
	INCLUDE_PATH	=> ['_templates', '/omd/sites/test/perl-lib/'],
#	PRE_PROCESS     => 'header.tt2',
	POST_CHOMP      => 1,
	PRE_CHOMP       => 1,
	TRIM            => 1,
	EVAL_PERL       => 1,
	INTERPOLATE     => 0,
	LOAD_PERL	=> 1,
});

# Always know who's asking us...
my $user = $ENV{REMOTE_USER} || $ENV{AUTHENTICATED_UID} || 'Unknown';

print header;
$template->process("gpad/$ajaxlet/$request.tt2", {
	ENV	=> \%ENV,
	q	=> $q,
	user	=> $user,
	param	=> sub { param(@_) },
});
if($template->error()) {
	print start_html, '<pre>' . $template->error() . '</pre>' . end_html;
}

exit 0;
