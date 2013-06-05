#!/usr/bin/perl -w

use CGI;
use Data::Dumper;
use HTML::Entities;

$cgi = new CGI();

# Save user input as hash of parameters
my %params = map { $_ => HTML::Entities::encode(join("; ",
    split("\0", $cgi->Vars->{$_}))) } $cgi->param;

# Convert any parameters embedded in "user_params" to actual parameters. This
# happens when a URL has extra path parts besides a controller and action.
# Example:
#
# URL typed by user:
# http://domain.tld/dns-tools/nscheck/barrioearth.com/verbose
#
# URL rewritten by apache mapped as /:controller/:action/:user_params
# http://domain.tld/index.cgi?controller=dns-tools&action=nscheck&user_params=/barrioearth.com/verbose
#
# Equivalent URL (what user would type with no rewrites post processing):
# http://domain.tld/index.cgi?controller=dns-tools&action=nscheck&domain=barrioearth.com&verbose=1
#
my @user_params;
if ($params{'user_params'}) {
    foreach (split('/', $params{'user_params'})) {
        push(@user_params, $_);
    }
}

# Handle user parameters if they exist. For the nscheck script, the first
# parameter is the domain while the rest are options
if (@user_params) {
    my $i = 0;
    foreach (@user_params) {
        unless ($i) {
            $params{'domain'} = $_;
        }
        else {
            my @dyad = split(':', $_);
            $dyad[1] = '1' unless $dyad[1];
            $params{$dyad[0]} = $dyad[1];
        }
        $i++;
    }
}

# TODO: convert nscheck to perl module instead

# Build args from params hash (should be done in nscheck.pl script instead)
my @debug;
my @args;
my %arg_pairs;
foreach $key (keys %params) {
    next if $key eq 'controller' || $key eq 'action' || $key eq 'user_params';
    my $arg = '';
    if ($key eq 'domain') {
        $arg = $params{$key};
    } else {
        $arg = '--' . $key;
    }
    push(@args, $arg);
}
# Build args from user parameter array
#my @args;
#$i = 0;
#foreach (@user_params) {
#    my $arg = $_;
#    $arg = '--' . $arg if $i;
#    push(@args, $arg);
#    $i++;
#}
my $cmd = 'perl nscheck.pl ' . join(' ', @args);
my $result = qx{$cmd};

# Ouput
print $cgi->header();

print '<?xml version="1.0" encoding="UTF-8"?>';

print '
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict
  //EN\"\"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
   <head>

        <title>Perl CGI test</title>
   </head>
   <body>';

print '
      <pre>';

print $result;

print '
      </pre>';

print '
   </body>

</html>
';
