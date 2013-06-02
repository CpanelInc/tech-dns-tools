#!/usr/bin/perl

=head1 NAME

nscheck - Queries TLD servers for a domain's nameservers

=head1 SYNOPSIS

  nscheck [options] <domain>

  Help Options:
   --help     Show this scripts help information.
   --manual   Read this scripts manual.
   --version  Show the version number and exit.

=cut


=head1 OPTIONS

=over 8

=item B<--help>
Show the brief help information.

=item B<--manual>
Read the manual, with examples.

=item B<--version>
Show the version number and exit.

=back

=cut


=head1 EXAMPLES

  The following is an example of this script:

 nscheck --verbose --ipv6 myawesomedomain.tld

=cut


=head1 DESCRIPTION


  This program will query the suffix servers that correspond for the
 specified domain. It will attempt to download a database maintained by Mozilla
 to determine the domain's "public suffix" (also called the "effective tld").
 For example, for domain.co.uk, the public suffix is "co.uk" while the true TLD
 is "uk". It will then query both the public suffix servers and the true
 TLD servers to learn the domain's nameservers and glue records.

=cut


=head1 AUTHOR


 Brian Warren
 --
 brian.warren@cpanel.net

 $Id: nscheck,v 0.8 2013/05/27 10:39:00 brian Exp $

=cut

use 5.008008;
use strict;
use warnings;

use Getopt::Long;
use Data::Dumper;

# Globals
my $VERSION = '0.1';
my $RELEASE = '0.1';
my $domain;
my @domain_parts;
my $tld;
my $etld;
my %options;
my $root_domain;
my @suffixes_to_query;
my $effective_tld_names_file = '/tmp/effective_tld_names.dat';
my $hr_bold = "\n" . '#' x 50 . "\n";
my $hr = "\n" . '-' x 50 . "\n";

# Default options
%options = (
    'brief' => 0,
    'check-all' => 0,
    'debug' => 0,
    'dig', => 0,
    'help' => 0,
    'ipv6' => 0,
    'manual' => 0,
    'public-suffix' => 1,
    'show-servers' => 0,
    'verbose' => 0,
    'version' => $VERSION
);

# Process command line arguments
process_args();

sub process_args {
    Getopt::Long::GetOptions(
        'b|brief' => \$options{'brief'},
        'check-all' => \$options{'check-all'},
        'debug', \$options{'debug'},
        'dig', \$options{'dig'},
        'help', \$options{'help'},
        'ipv6', \$options{'ipv6'},
        'manual', \$options{'manual'},
        'public-suffix', \$options{'public-suffix'},
        'show-servers', \$options{'show-servers'},
        'v|verbose', \$options{'verbose'},
        'version', \$options{'version'}
    ) or Pod::Usage::pod2usage(2);

    $domain = $ARGV[0] || '';
    $domain =~ s/[\.]+$//; # Remove any trailing dots
    @domain_parts = split(/\./, $domain);
    $tld = $domain_parts[-1];
    $etld = $tld; # Default value, may change

    $options{'help'} = 1 unless $domain && $#domain_parts;

    if (!$options{'version'} && ($options{'manual'} or $options{'help'})) {
        require 'Pod/Usage.pm';
        import Pod::Usage;
        Pod::Usage::pod2usage(1) if $options{'help'};
        Pod::Usage::pod2usage(VERBOSE => 2) if $options{'manual'}; 
    }

    if ($VERSION) {
        my $REVISION  = '$Id: nscheck,v 0.10 2013/05/27 10:44:12 brian Exp $';
        $VERSION = join (' ', (split (' ', $REVISION))[2]);
        $VERSION =~ s/,v\b//;
        $VERSION =~ s/(\S+)$/$1/;

        print "nscheck release $RELEASE - CVS: $VERSION\n";
    }
}

# Options interdependencies
if ($options{'debug'}) {
    $options{'verbose'} = 1;
    $options{'ipv6'} = 1;
    $options{'show-servers'} = 1;
    $options{'brief'} = 0;
}
elsif ($options{'verbose'}) {
    $options{'brief'} = 0;
}

# Enable the ability to conditionally use some modules
# Domain::PublicSuffix - derive root domain and effective TLD.
# Net::DNS - perform DNS queries
# LWP::Simple - perform simple web requests
my @modules = ('Domain::PublicSuffix', 'Net::DNS', 'LWP::Simple');
my %module_available;
foreach (@modules) {
    next if $_ eq $options{'dig'} && $_ == 'Net::DNS';
    next if $_ eq $options{'public-suffix'} && $_ == 'Domain::PublicSuffix';
    $module_available{$_} = import_module_if_found($_);
}

# DEBUG START # pretend certain modules are not available
#$module_available{'Domain::PublicSuffix'} = 1;
#$module_available{'Net::DNS'} = 1;
#$module_available{'LWP::Simple'} = 1;
#print Dumper(%module_available);exit;
# DEBUG END #

# Download effective_tld_names.dat
if ($module_available{'LWP::Simple'}) {
    # Download unless the file exists and is less than 7 days old
    unless (-e $effective_tld_names_file && -M $effective_tld_names_file < 7) {
        my $url = 'http://mxr.mozilla.org/mozilla-central/source/netwerk' .
            '/dns/effective_tld_names.dat?raw=1';
        getstore($url, $effective_tld_names_file);
    }
}

# Use Domain::PublicSuffix if available to determine public suffix, also called
# "effective tld".
if ($options{'public-suffix'} && $module_available{'Domain::PublicSuffix'}) {
    my $publicSuffix = Domain::PublicSuffix->new({
        'data_file' => $effective_tld_names_file
    });
    $root_domain = $publicSuffix->get_root_domain($domain);

    if ( $publicSuffix->error ) {
        printf( "%12s: %s\n", 'Error', $publicSuffix->error );
        exit(1);
    }
    else {
        $tld = $publicSuffix->tld;
        $etld = $publicSuffix->suffix;
        push(@suffixes_to_query, $etld);
        push(@suffixes_to_query, $tld) if $tld ne $etld;
    }
}
# If Domain::PublicSuffix is not available, figure out suffixes using
# downloaded database file
else { 
    if (-e $effective_tld_names_file) {
        my $domain_parts_offset = 2;
        open SUFFIX_FILE, '<', $effective_tld_names_file;
        while (<SUFFIX_FILE>) {
            if (/^\/\/ $tld/../^$/) {
                next if /^\/\// || /^$/;
                chomp ( my $this_suffix = $_ );

                # Loop through possible public suffixes. First match is
                # considered to be the etld
                for $domain_parts_offset (2..scalar @domain_parts) {
                    my $possible_suffix = join('.',
                        @domain_parts[-$domain_parts_offset..-1]);
                    if ($possible_suffix eq $this_suffix) {

                        # Assume that etld is the first suffix that is not the tld
                        $etld = $this_suffix;
                        unshift(@suffixes_to_query, $possible_suffix); 
                        last; # Break out of loop since there should only ever
                               # be one match, which is the etld
                    }
                }
            }
        }
        # Rebuild root domain from parts
        $root_domain = $domain_parts[-$domain_parts_offset - 1] . '.' . $etld;
        push(@suffixes_to_query, $tld);
    }
    # If no database file exists, assume that user provided root domain and
    # that the last part is the TLD. If the domain has three parts, then
    # assume that the last two parts is the public suffix
    else {
        # Prune domain so it has just 3 parts (assumes that the suffix is no
        # more that two parts)
        if (scalar @domain_parts > 3) {
            @domain_parts = @domain_parts[-3..-1];
        }
        if (scalar @domain_parts > 2) {
            $etld = join('.', @domain_parts[-2..-1]);
        }
        push(@suffixes_to_query, $etld);
        push(@suffixes_to_query, $tld) if $tld ne $etld;
    }
    $root_domain =~ s/\.$etld//;
    my @stem_parts = split(/\./, $root_domain);
    $root_domain = $stem_parts[-1] . '.' . $etld;
}

unless ($options{'brief'}) {
    print $hr_bold;
    printf("%15s: %s\n", 'Domain', $domain);
    printf("%15s: %s\n", 'Root domain', $root_domain );
    printf("%15s: %s\n", 'Public suffix', $etld);
    printf("%15s: %s", 'True TLD', $tld);
    print $hr_bold;
}

# Get nameservers for the effective tld and the true tld
for (my $i = 0; $i < $#suffixes_to_query + 1; $i++) {
    my $suffix = $suffixes_to_query[$i];
    print "\n## Suffix: ${suffix}\n";
    my @names = get_nameservers($suffix);
    unless (@names) {
        print "No nameservers found for this suffix.\n\n";
        next;
    }
    printf("%s\n", 'Suffix servers:') if $options{'show-servers'};
    my @ips;
    for (my $j = 0; $j < $#names + 1; $j++) {
        my $name = $names[$j];
        my $ip = a_lookup($name);
        push(@ips, $ip) if $ip;
        printf("%-23s %s\n", $name, $ip) if $options{'show-servers'};
    }
    if (@ips) {
        # Ask the TLD servers for authoritative nameservers of domain
        print suffix_nameserver_report($root_domain, \@ips);
    }
    else {
        print 'Error! None of the nameservers for the suffix "' .
            " ${suffixes_to_query[$i]}\" resolve to an IP address.\n";
    }
}

sub get_nameservers {
    my $this_domain = shift;
    if (! $options{'dig'} && $module_available{'Net::DNS'}) {
        return get_nameservers_Net_Dns($this_domain);
    }
    return get_nameservers_dig($this_domain);
}

sub get_nameservers_Net_Dns {
    my $this_domain = shift;
    my $res = Net::DNS::Resolver->new;
    my $query = $res->query("${this_domain}.", 'NS');
    my @nameservers;
    if ($query) {
        foreach my $rr (grep { $_->type eq 'NS' } $query->answer) {
            push(@nameservers, $rr->nsdname);
        }
    }
    else {
        warn "query failed: ", $res->errorstring, "\n";
    }
    return @nameservers;
}

sub get_nameservers_dig {
    my $this_domain = shift;
    chomp( my $result = qx(dig NS \@8.8.8.8 ${this_domain}. +short) );
    $result =~ s/\.$//;
    my @result = split(/\.\n/, $result);
}

sub a_lookup {
    my $this_domain = shift;
    if (! $options{'dig'} && $module_available{'Net::DNS'}) {
        return a_lookup_Net_Dns($this_domain);
    }
    return a_lookup_dig($this_domain);
}

sub a_lookup_Net_Dns {
    my $this_domain = shift;
    my $res = Net::DNS::Resolver->new;
    my $query = $res->query("${this_domain}.", 'A');
    my @answers;
    if ($query) {
        foreach my $rr (grep { $_->type eq 'A' } $query->answer) {
            push(@answers, $rr->address);
        }
    }
    else {
        warn "query failed: ", $res->errorstring, "\n";
    }
    return $answers[0] || '';
}

sub a_lookup_dig {
    my $this_domain = shift;
    my $cmd = "dig A \@8.8.8.8 ${this_domain}. +short";
    chomp( my $result = qx($cmd) );
    unless ($result) {
        warn("query failed: \`$cmd\`") if $options{'debug'};
        return '';
    }
    my @answers = split(/\n/, $result);
    return $answers[0] || '';
}

sub suffix_nameserver_report {
    my $this_domain = $_[0];
    my @suffix_nameserver_ips = @{$_[1]};

    # Randomly select one of the suffix nameserver IPs to use as resolver
    my $high = scalar @suffix_nameserver_ips;
    my $random_offset = 0 + int rand($high - 1);
    my $suffix_nameserver_ip = $suffix_nameserver_ips[$random_offset];
    if ($options{'verbose'}) {
        print "\nQuerying suffix server $suffix_nameserver_ip...\n";
    }

    my @result;
    if ($module_available{'Net::DNS'} && ! $options{'dig'}) {
        @result = nameserver_sections_Net_Dns($this_domain,
            $suffix_nameserver_ip);
    }
    else {
        @result = nameserver_sections_dig($this_domain, $suffix_nameserver_ip);
    }
    my @authority = @{$result[0]};
    my @additional = @{$result[1]}; 
    return "\n" . nameserver_sections_to_text(\@authority, 'authority') . "\n" .
        nameserver_sections_to_text(\@additional, 'additional') . "\n";
}

sub nameserver_sections_Net_Dns {
    my $this_domain = $_[0];
    my $suffix_nameserver_ip = $_[1];
    my $res = Net::DNS::Resolver->new(
        nameservers => [($suffix_nameserver_ip)],
        recurse => 0,
      	debug => 0,
    );
    my $packet = $res->send("${this_domain}.", 'A');
    my (@authority_hashes, @additional_hashes);
    for my $rr ($packet) {
        push(@authority_hashes, $rr->authority);
        push(@additional_hashes, $rr->additional);
    }
    return (\@authority_hashes, \@additional_hashes);
}

sub nameserver_sections_dig {
    my $this_domain = $_[0];
    my $suffix_nameserver_ip = $_[1];
    my $cmd = "dig \@$suffix_nameserver_ip A $this_domain." .
        ' +noall +authority +additional +comments';
    print "\nUsing dig:\n$cmd\n";
    chomp(my $result = qx($cmd));
    my @lines = split(/\n/, $result);
    my @authority_lines = items_between(\@lines, ';; AUTHORITY', '');
    my @additional_lines = items_between(\@lines, ';; ADDITIONAL', '');
    my @authority_hashes = @{hashify_suffix_server_response('authority',
        \@authority_lines)};
    my @additional_hashes = @{hashify_suffix_server_response('additional',
        \@additional_lines)};
    return (\@authority_hashes, \@additional_hashes);
}

# # # # # #
sub suffix_nameserver_report {
    my $this_domain = $_[0];
    my @suffix_nameserver_ips = @{$_[1]};
    my @ips_to_query;
    if ($options{'check-all'}) {
        @ips_to_query = @suffix_nameserver_ips;
    } else {
        # Randomly select one of the suffix nameserver IPs to use as resolver
        my $high = scalar @suffix_nameserver_ips;
        my $random_offset = 0 + int rand($high - 1);
        @ips_to_query = ($suffix_nameserver_ips[$random_offset]);
    }
    my $result = '';
    foreach my $ip (@ips_to_query) {
        $result .= "\nQuerying suffix server $ip...\n" if $options{'verbose'};
        my $sections = nameserver_sections($domain, $ip));
        $result .= "\n" .
            nameserver_sections_to_text(@{$sections->{'authority'}},
                'authority') . "\n" .
            nameserver_sections_to_text(@{$sections->{'additional'}},
                'additional') . "\n";
    }
    return $result;
}
sub nameserver_sections {
    my $domain = shift;
    my $ip = shift;
    return nameserver_sections_from_dig($domain, $ip) if $options{'dig'};
    return nameserver_sections_from_Net_DNS($domain, $ip);
}
sub nameserver_sections_from_dig {
    my $domain = shift;
    my $ip = shift;
    my $cmd = "dig \@$ip A $domain. +noall +authority +additional +comments";
    print "\nUsing dig:\n$cmd\n";
    chomp(my $result = qx($cmd));
    my @lines = split(/\n/, $result);
    my @authority_lines = items_between(\@lines, ';; AUTHORITY', '');
    my @additional_lines = items_between(\@lines, ';; ADDITIONAL', '');
    my @authority_hashes = @{hashify_suffix_server_response('authority',
        \@authority_lines)};
    my @additional_hashes = @{hashify_suffix_server_response('additional',
        \@additional_lines)};
    return {
        'authority' => \@authority_hashes,
        'additional' => \@additional_hashes
    };
}
sub nameserver_sections_from_Net_DNS {
    my $this_domain = $_[0];
    my $suffix_nameserver_ip = $_[1];
    my $res = Net::DNS::Resolver->new(
        nameservers => [($suffix_nameserver_ip)],
        recurse => 0,
      	debug => 0,
    );
    my $packet = $res->send("${this_domain}.", 'A');
    my (@authority_hashes, @additional_hashes);
    for my $rr ($packet) {
        push(@authority_hashes, $rr->authority);
        push(@additional_hashes, $rr->additional);
    }
    return {
        'authority' => \@authority_hashes,
        'additional' => \@additional_hashes
    };
}
# # # # # #


sub nameserver_sections_to_text {
    my @input = @{$_[0]};
    my $section = $_[1];
    my $format = {};
    $format->{'authority'} = {
        header => 'Nameservers:',
        columns => [ qw(nsdname) ]
    };
    $format->{'additional'} = {
        header => 'Glue records:',
        columns => [ qw(name address) ]
    };
    if ($options{'verbose'}) {
        $format->{'authority'} = {
            header => ';; AUTHORITY SECTION:',
            columns => [ qw(name ttl class type nsdname) ]
        };
        $format->{'additional'} = {
            header => ';; ADDITIONAL SECTION:',
            columns => [ qw(name ttl class type address) ]
        };
    }
    my @out;
    push(@out, $format->{$section}->{'header'});
    foreach my $line_hash (@input) {
        next if !$options{'ipv6'} && $line_hash->{'type'} eq 'AAAA';
        my @line_array;
        foreach my $column_name (@{$format->{$section}->{'columns'}}) {
            push(@line_array, $line_hash->{$column_name});
        }
        my $line = join('   ', @line_array);
        push(@out, $line);
    }
    return join("\n", @out) . "\n";
}

sub hashify_suffix_server_response {
    my $section = $_[0];
    my @input = @{$_[1]};
    my @keys = ('name', 'ttl', 'class', 'type');
    if ($section eq 'authority') {
        push(@keys, 'nsdname');
    }
    else {
        push(@keys, 'address');
    }
    my @out;
    foreach (@input) {
        my %line_hash;
        my @column_values = split(/\s+/, $_);
        for (my $i = 0; $i < $#column_values + 1; $i++) {
            $line_hash{$keys[$i]} = $column_values[$i];
        }
        push(@out, \%line_hash);
    }
    return \@out;
}

sub items_between {
    my @input = @{$_[0]};
    my $start_pattern = $_[1];
    my $end_pattern = $_[2];
    my $filter_pattern = $_[3];
    my @result;
    foreach (@input) {
        if (/^$start_pattern/../^$end_pattern$/) {
            next if /^$start_pattern/ || /^$end_pattern$/;
            if ($filter_pattern) {
                next if /$filter_pattern/;
            }
            push(@result, $_);
        }
    }
    return @result;;
}

sub import_module_if_found {
    my $module = shift;
    eval {
        (my $file = $module) =~ s|::|/|g;
        require $file . '.pm';
        $module->import();
        return 1;
    } or do {
        return 0;
    }
}

sub usage {
	my ( $error ) = @_;
	printf("%s\n", 'Usage: nscheck [options...] <hostname>');
    printf("%s\n", 'Options');
	printf("%6s%-16s%-48s\n", '-b, ', '--brief', 'Show brief output');
	printf("%6s%-16s%-48s\n", '', '--debug', 'Show debugging output');
	printf("%6s%-16s%-48s\n", '', '--dig',
        'Use dig instead of Net::DNS to perform queries');
	printf("%6s%-16s%-48s\n", '', '--ipv6', 'Show ipv6 records');
	printf("%6s%-16s%-48s\n", '', '--show-servers',
        'Show list of suffix servers');
	printf("%6s%-16s%-48s\n", '', '--public_suffix',
        'Attempt to determin public suffix via mozilla database');
	printf("%6s%-16s%-48s\n", '-v, ', '--verbose', 'Show verbose output');
	exit(1);
}

1;
