#!/usr/bin/perl

#############################################################################
#                                                                           #
# This script was initially developed by Infoxchange for internal use        #
# and has kindly been made available to the Open Source community for       #
# redistribution and further development under the terms of the             #
# GNU General Public License v3: http://www.gnu.org/licenses/gpl.html       #
#                                                                           #
#############################################################################
#                                                                           #
# This script is supplied 'as-is', in the hope that it will be useful, but  #
# neither Infoxchange nor the authors make any warranties or guarantees     #
# as to its correct operation, including its intended function.             #
#                                                                           #
# Or in other words:                                                        #
#       Test it yourself, and make sure it works for YOU.                   #
#                                                                           #
#############################################################################
# Author: George Hansper                     e-mail:  george@hansper.id.au  #
#############################################################################

use strict;
use LWP;
use LWP::UserAgent;
use Getopt::Std;
use XML::XPath;
#use Data::Dumper;

my %optarg;
my $getopt_result;

my $lwp_user_agent;
my $http_request;
my $http_response;
my $url;
my $body;

my @message;
my $exit = 0;
my @exit = qw/OK: WARNING: CRITICAL: UNKNOWN:/;

my $rcs_id = '$Id$';
my $rcslog = '
	$Log$
	';

my $timeout = 10;			# Default timeout
my $host = 'api.newrelic.com';
my @app_incl = ();
my @app_excl = ();
my @apps_excluded = ();
my %app_id2name = ();
my %app_name2id = ();
my $API_key = '';
my %url = (
	accounts => 'https://api.newrelic.com/api/v1/accounts.xml',
	applications => 'https://api.newrelic.com/api/v1/accounts/:account_id/applications.xml',
#	servers_for_app => 'https://api.newrelic.com/api/v1/accounts/:account_id/applications/:app_id/servers.xml',
#	app_settings => 'https://api.newrelic.com/api/v1/accounts/:account_id/application_settings/:app_id.xml',
	app_thresholds => 'https://api.newrelic.com/api/v1/accounts/:account_id/applications/:app_id/thresholds.xml',
	app_metrics => 'https://api.newrelic.com/api/v1/accounts/:account_id/applications/:app_id/threshold_values.xml',

);

my $account_id = '';
my @app_ids = ();
my %app_metrics = ();
my %app_thresholds;
my %app_metric_values;
my %message;
my @message_perf;

my %uri = ();

$getopt_result = getopts('hvdH:t:a:A:k:', \%optarg) ;

sub HELP_MESSAGE() {
	print <<EOF;
Usage:
	$0 [-v] [-H hostname] -k API_key [-t time_out] [-a app_regex,...] [-A app_regex,...]

	-k  ... API key from Newrelic - ** REQUIRED ** (see below)
	-H  ... Hostname and Host: header (default: $host)
	-v  ... verbose messages to STDERR
	-d  ... debug messages to STDERR for testing (http headers and repoonses)
	-t  ... Seconds before connection times out. (default: $timeout)
	-a  ... Include only applications listed (format is regex,regex,...)
	-A  ... exclude applications listed (only valid without -a...)

Notes:
	The api_key is generated by Newrelic > Account settings > Integrations > Data Sharing > API access.
	See:
		https://newrelic.com/docs/features/getting-started-with-the-new-relic-rest-api

	-t sets the timeout on each HTTPS GET transaction, and not the overall check


Examples:
	$0 -k 1234abcetc
		... check all apps against their Newrelic thresholds (defined in newrelic)
		    This makes 2 calls to the API per application, so it can take a while to execute the entire check

	$0 -k 1234abcetc -a '[Pp]rod'
		... check all apps with a name containing 'Prod' or 'prod'

	$0 -k 1234abcetc -A dev,Dev
		... check all apps excluding those whose name contains Dev or dev

EOF
}

# Any invalid options?
if ( $getopt_result == 0 ) {
	HELP_MESSAGE();
	exit 1;
}
if ( $optarg{h} ) {
	HELP_MESSAGE();
	exit 0;
}
sub VERSION_MESSAGE() {
	print "$^X\n$rcs_id\n";
}

sub printv($) {
	my $str = $_[0];
	if ( $optarg{v} ) {
		chomp $str;
		print STDERR $str;
		print STDERR "\n";
	}
}

sub print_debug($) {
	if ( $optarg{d} ) {
		chomp( $_[-1] );
		print STDERR @_;
		print STDERR "\n";
	}
}

if ( defined($optarg{t}) ) {
	$timeout = $optarg{t};
}

if ( defined($optarg{k}) ) {
	$API_key = $optarg{k};
}


if ( defined($optarg{H}) ) {
	$host = $optarg{H};
	my $key;
	foreach $key ( keys(%url) ) {
		$url{$key} =~ s/api\.newrelic\.com/$host/;
	}
}


if ( defined($optarg{a}) ) {
	@app_incl = split(/,/,$optarg{a});
}

if ( defined($optarg{A}) ) {
	@app_excl = split(/,/,$optarg{A});
}

$lwp_user_agent = LWP::UserAgent->new;
$lwp_user_agent->timeout($timeout);

$lwp_user_agent->default_header( 'X-api-key' => $API_key );

sub http_get_body($) {
	# We're re-using the same lwp_user_agent object - it still has our X-api-key: header
	my $url = $_[0];
	$http_request = HTTP::Request->new(GET => $url);
	print_debug "--------------- GET $url";
	print_debug $lwp_user_agent->default_headers->as_string . $http_request->headers_as_string;

	$http_response = $lwp_user_agent->request($http_request);
	if ( defined($http_response->headers_as_string) ) {
		print_debug "---------------\n" . $http_response->protocol . " " . $http_response->status_line;
		print_debug $http_response->headers_as_string;
	}
	if ($http_response->is_success) {
		print_debug "Content has " . length($http_response->content) . " bytes \n";
		$body = $http_response->content;
		print_debug("$body");
		return($body);
	} else {
		push @message, "CRITICAL: $url " . $http_response->protocol . " " . $http_response->status_line;
		$exit |= 2;
		return("");
	}
}

#----------------------------------------------------------------------------
# Get account_id for this API_key
$url = $url{accounts};
$body = http_get_body($url);

if ($body ne "" ) {
	#printv "Content has " . length($http_response->content) . " bytes \n";
	#$body = $http_response->content;
	#printv("$body");
	my $xpath = XML::XPath->new( xml => $body );
	$account_id= $xpath->getNodeText('/accounts/account/id');
	printv "account_id=$account_id\n";
}
#----------------------------------------------------------------------------
# Get the application names and id's for this account
$url = $url{applications};
$url =~ s/:account_id/$account_id/;
$body = http_get_body($url);

if ($body ne "" ) {
	my $xpath = XML::XPath->new( xml => $body );
	my $nodeset = $xpath->find('/applications/application');
	my $app_node;
	foreach $app_node ( $nodeset->get_nodelist ) {
		#printv Dumper($app_node);
		my $app_name;
		my $app_id;
		$app_name = $xpath->findvalue('./name',$app_node)->string_value;
		$app_id = $xpath->findvalue('./id',$app_node)->string_value;
		printv "$app_name = $app_id\n";
		$app_id2name{$app_id} = $app_name;
		$app_name2id{$app_name} = $app_id;
		if ( @app_incl > 0 && grep($app_name =~ /$_/, @app_incl) == 0 ) {
			printv "$app_name not in list ". join(",",@app_incl). "\n";
			next;
		} elsif ( @app_excl > 0 && grep($app_name =~ /$_/, @app_excl) > 0 ) {
			printv "$app_name excluded by list ". join(",",@app_excl). "\n";
			push @apps_excluded, $app_name;
			next;
		}
		push @app_ids,$app_id;
	}
}

#----------------------------------------------------------------------------
# Get the warning (caution-value) and critical (critical-value) for each application by application id
sub get_thresholds($) {
	my $app_id = $_[0];
	printv "-----------------";
	printv "$app_id2name{$app_id} = $app_id\n";
	$url = $url{app_thresholds};
	$url =~ s/:account_id/$account_id/;
	$url =~ s/:app_id/$app_id/;
	$body = http_get_body($url);

	if ($body ne "" ) {
		my $xpath = XML::XPath->new( xml => $body );
		my $nodeset = $xpath->find('/thresholds/threshold');
		my $node;
		foreach $node ( $nodeset->get_nodelist ) {
			#printv Dumper($app_node);
			my $id;
			my $type;
			my $warn;
			my $crit;
			$type = $xpath->findvalue('./type',$node)->string_value;
			$id = $xpath->findvalue('./id',$node)->string_value;
			$warn = $xpath->findvalue('./caution-value',$node)->string_value;
			$crit = $xpath->findvalue('./critical-value',$node)->string_value;
			printv "$type = $id $warn $crit\n";
			$app_thresholds{$app_id}{$type}{warn}=$warn;
			$app_thresholds{$app_id}{$type}{crit}=$crit;
		}
	}
}

#----------------------------------------------------------------------------
# Get the current metrics for each app_id
sub get_metrics($) {
	my $app_id = $_[0];
	#printv "$app_id";
	$url = $url{app_metrics};
	$url =~ s/:account_id/$account_id/;
	$url =~ s/:app_id/$app_id/;

	$body = http_get_body($url);

	if ($body ne "" ) {
		$body = $http_response->content;
		my $xpath = XML::XPath->new( xml => $body );
		my $nodeset = $xpath->find('/threshold-values/threshold_value');
		my $node;
		foreach $node ( $nodeset->get_nodelist ) {
			#printv Dumper ($node);
			my $type;
			my $value;
			$type = $xpath->findvalue('@name',$node)->string_value;
			# Nasty hack because Newrelic provides metrics for 'Error Rate' but sets thresholds for ErrorRate
			$type =~ s/Error Rate/ErrorRate/;
			$value = $xpath->findvalue('@metric_value',$node)->string_value;
			#$value = $xpath->findvalue('@formatted_metric_value',$node)->string_value;
			printv "$type = $value\n";
			$app_metric_values{$app_id}{$type}=$value;
			$app_metrics{$type} = 1;
		}
	}
}
my $app_id;
foreach $app_id ( @app_ids ) {
	my $app_name = $app_id2name{$app_id};
	my $app_name_perf = $app_name;
	$app_name_perf =~ s/ //g;
	get_thresholds($app_id);
	get_metrics($app_id);
	if ( keys( %{$app_metric_values{$app_id}} ) == 0 ) {
		printv "No metrics for app $app_id $app_name\n";

	}

	# Set exit code as per thresholds
	#----------------------------------------------------------------------------
	my $app_status = 0;
	my @app_message_warn = ();
	my @app_message_crit = ();
	my $type;
	my @app_message_perf = ();
	foreach $type ( keys(%app_metrics) ) {
		my $type_name_perf = $type;
		$type_name_perf =~ s/ //g;
		if ( defined( $app_thresholds{$app_id}{$type}{warn} ) ) {
			if ( $app_thresholds{$app_id}{$type}{warn} > $app_thresholds{$app_id}{$type}{crit} ) {
				if ( $app_metric_values{$app_id}{$type} < $app_thresholds{$app_id}{$type}{crit} ) {
					$app_status = 2;
					push @app_message_crit, "$type=$app_metric_values{$app_id}{$type}(<$app_thresholds{$app_id}{$type}{crit})";
				} elsif ( $app_metric_values{$app_id}{$type} < $app_thresholds{$app_id}{$type}{warn} ) {
					$app_status = 1;
					push @app_message_warn, "$type=$app_metric_values{$app_id}{$type}(<$app_thresholds{$app_id}{$type}{warn})";
				}
			} else {
				if ( $app_metric_values{$app_id}{$type} > $app_thresholds{$app_id}{$type}{crit} ) {
					$app_status = 2;
					push @app_message_crit, "$type=$app_metric_values{$app_id}{$type}(>$app_thresholds{$app_id}{$type}{crit})";
				} elsif ( $app_metric_values{$app_id}{$type} > $app_thresholds{$app_id}{$type}{warn} ) {
					$app_status = 1;
					push @app_message_warn, "$type=$app_metric_values{$app_id}{$type}(>$app_thresholds{$app_id}{$type}{warn})";
				}
			}
			push @app_message_perf,"${app_name_perf}_$type_name_perf=$app_metric_values{$app_id}{$type};$app_thresholds{$app_id}{$type}{warn};$app_thresholds{$app_id}{$type}{crit}";
		} else {
			# No thresholds (omit from performance data
			push @app_message_perf,"${app_name_perf}_$type_name_perf=$app_metric_values{$app_id}{$type}";
		}
	}
	if ( $app_status == 0 ) {
		$message{$app_id} = "OK";
	} elsif ( $app_status == 1 ) {
		$message{$app_id} = "WARN " .join(" ",@app_message_warn);
	} else {
		$message{$app_id} = "CRIT " .join(" ",@app_message_crit);
	}
	$exit |= $app_status;
	push @message, "$app_name: $message{$app_id}";
	push @message_perf,join(" ",@app_message_perf);
}

if ( @app_ids == 0 ) {
	if ( @app_incl > 0 ) {
		push @message, "No apps found matching ".join(",",@app_incl);
	} elsif ( @apps_excluded > 0 ) {
		push @message, "No apps left after excluding".join(",",@apps_excluded);
	} else {
		push @message, "No apps found";
	}
	$exit |= 1;
}

if ( $exit == 3 ) {
	$exit = 2;
} elsif ( $exit > 3 || $exit < 0 ) {
	$exit = 3;
}

print "$exit[$exit] ". join(", ",@message)."|".join(" ",@message_perf) . "\n";
exit $exit;
