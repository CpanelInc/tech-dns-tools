#!/usr/bin/perl
use 5.008008;
use strict;
use warnings;

use Getopt::Long;
use Data::Dumper;

# TODO:
# - Filter Net::DNS results according to verbosity
# - Show which suffix server is being used to derive domain's nameservers

# Options
my %options;
$options{'brief'} = 0;
$options{'debug'} = 0;
$options{'dig'} = 0;
$options{'help'} = 0;
$options{'ipv6'} = 0;
$options{'man'} = 0;
$options{'public_suffix'} = 1;
$options{'show_servers'} = 0;
$options{'verbose'} = 0;

#print Dumper($options{'verbose'});
process_args(@ARGV);
#print Dumper($options{'verbose'});
#exit;

sub process_args {
    Getopt::Long::GetOptions(
        'b|brief' => \$options{'brief'},
        'debug', \$options{'debug'},
        'dig', \$options{'dig'},
        'ipv6', \$options{'ipv6'},
        'show-servers', \$options{'show_servers'},
        'public-suffix', \$options{'public_suffix'},
        'v|verbose', \$options{'verbose'}
    ) or Pod::Usage::pod2usage(2);
    if ($options{'man'} or $options{'help'}) {
        require 'Pod/Usage.pm';
        import Pod::Usage;
        Pod::Usage::pod2usage(1) if $options{'help'};
        Pod::Usage::pod2usage(VERBOSE => 2) if $options{'man'};
    }
}

# Options interdependencies
if ($options{'debug'}) {
    $options{'verbose'} = 1;
    $options{'ipv6'} = 1;
    $options{'show_servers'} = 1;
    $options{'brief'} = 0;
}
elsif ($options{'verbose'}) {
    $options{'show_servers'} = 1;
    $options{'brief'} = 0;
}

#print Dumper(%options);exit; # DEBUG

my $domain = shift(@ARGV) || '';
$domain =~ s/[\.]+$//; # Remove any trailing dots
my @domain_parts = split(/\./, $domain);
unless ($domain && $#domain_parts + 1 > 1) {
    usage('A valid domain name is required.')
}

my $hr_bold = "\n" . '=' x 80 . "\n";
my $hr = "\n" . '-' x 80 . "\n";

# Enable the ability to conditionally use some modules
# Domain::PublicSuffix - derive root domain and effective TLD.
# Net::DNS - perform DNS queries
# LWP::Simple - perform simple web requests
my @modules = ('Domain::PublicSuffix', 'Net::DNS', 'LWP::Simple');
my %module_available;
foreach (@modules) {
    next if $_ eq $options{'dig'} && $_ == 'Net::DNS';
    next if $_ eq $options{'public_suffix'} && $_ == 'Domain::PublicSuffix';
    $module_available{$_} = import_module_if_found($_);
}

# DEBUG START # pretend certain modules are not available
#$module_available{'Domain::PublicSuffix'} = 1;
#$module_available{'Net::DNS'} = 1;
#$module_available{'LWP::Simple'} = 1;
#print Dumper(%module_available);exit;
# DEBUG END #

# Globals
my $root_domain;
my @suffixes_to_query;
my $effective_tld_names_file = '/tmp/effective_tld_names.dat';

# Download effective_tld_names.dat
if ($module_available{'LWP::Simple'}) {
    if (-e $effective_tld_names_file) {
        if (-M $effective_tld_names_file > 7) { # Download if a week old or more
            my $url = 'http://mxr.mozilla.org/mozilla-central/source/netwerk' .
                '/dns/effective_tld_names.dat?raw=1';
            getstore($url, $effective_tld_names_file);
        }
    }
}

# use domain::publicsuffix if available to determine public suffix, also called
# "effective tld".
if ($options{'public_suffix'} && $module_available{'domain::publicsuffix'}) {
    my $publicSuffix = domain::publicsuffix->new({
        'data_file' => $effective_tld_names_file
    });
    $root_domain = $publicSuffix->get_root_domain($domain);

    if ( $publicSuffix->error ) {
        printf( "%12s: %s\n", 'Error', $publicSuffix->error );
        exit(1);
    }
    else {
        push(@suffixes_to_query, $publicSuffix->suffix);
        if ($publicSuffix->tld ne $publicSuffix->suffix) {
            push(@suffixes_to_query, $publicSuffix->tld);
        }
    }    
}
# If Domain::PublicSuffix is not available, figure out suffixes using
# downloaded database file
else {
    my $tld = $domain_parts[-1];
    my $etld = join('.', @domain_parts[-2..-1]);
    if ($options{'public_suffix'} && -e $effective_tld_names_file) {
        open SUFFIX_FILE, '<', $effective_tld_names_file;
        while (<SUFFIX_FILE>) {
            if (/^\/\/ $tld/../^$/) {
                next if /^\/\// || /^$/;
                chomp ( my $this_suffix = $_ );
                if ($tld =~ /${this_suffix}$/ || $etld =~ /${this_suffix}$/) {
                    unshift(@suffixes_to_query, $this_suffix);
                }
            }
        }
        # Trim off any subdomain components in case they were included by user
        $root_domain = $domain;
        foreach(@suffixes_to_query) {
            if ($_ =~ /\./) {
                $root_domain =~ s/\.$_$//;
                my @stem_parts = split(/\./, $root_domain);
                $root_domain = $stem_parts[-1] . '.' . $_;
                last;
            }
        }
        unless ($root_domain) {
            $root_domain = join(splice(@domain_parts, -2, 2), '.');
        }
    }
    # If no database file exists, assume that user provided root domain and
    # that the last part is the TLD. If the domain has three parts, then
    # assume that the last two parts is the public suffix
    else {
        # Prune domain so it has just 3 parts (assumes that the suffix is no
        # more that two parts)
        my $etld;
        my @root_domain_parts = @domain_parts;
        if ($#domain_parts + 1 > 3) {
            @root_domain_parts = splice(@domain_parts, -3, 3);
        }
        $root_domain = join('.', @root_domain_parts);
        if ($#root_domain_parts + 1 > 2) {
            $etld = join('.', splice(@root_domain_parts, -2,2));
        }
        else {
            $etld = $domain_parts[-1];
        }
        push(@suffixes_to_query, $etld); # Add public suffix
        push(@suffixes_to_query, $domain_parts[-1]); # Add TLD
    }
}

unless ($options{'brief'}) {
    print $hr_bold;
    printf("%15s: %s\n", 'Domain', $domain);
    printf("%15s: %s\n", 'Root domain', $root_domain );
    printf("%15s: %s\n", 'Public suffix', $suffixes_to_query[0]);
    printf("%15s: %s", 'True TLD', $suffixes_to_query[1]);
    print $hr_bold;
}

if ($#suffixes_to_query) {
    if ($suffixes_to_query[0] eq $suffixes_to_query[1]) {
        pop(@suffixes_to_query);
    }
}

# Get nameservers for the effective tld and the true tld
#my $previous_suffix = '';
for (my $i = 0; $i < $#suffixes_to_query + 1; $i++) {
    my $suffix = $suffixes_to_query[$i];
    print "${hr}Suffix: ${suffix}${hr}";
    my @names = get_nameservers($suffix);
    unless (@names) {
        print "No nameservers found for this suffix.\n";
        next;
    }
    printf("%s\n", 'Suffix servers:') if $options{'show_servers'};
    my @ips;
    for (my $j = 0; $j < $#names + 1; $j++) {
        my $name = $names[$j];
        my $ip = a_lookup($name);
        push(@ips, $ip) if $ip;
        printf("%-23s %s\n", $name, $ip) if $options{'show_servers'};
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
    # TODO: Should this be an A query, or NS, or what?
    my $packet = $res->send("${this_domain}.", 'A');
    my (@authority_hashes, @additional_hashes);
    for my $rr ($packet) {
        push(@authority_hashes, $rr->authority);
        push(@additional_hashes, $rr->additional);
    }
    return (\@authority_hashes, \@additional_hashes);
}

# TODO: randomize which nameserver is used since this script currently
# always uses the same nameserver
sub nameserver_sections_dig {
    my $this_domain = $_[0];
    my $suffix_nameserver_ip = $_[1];
    # TODO: find out why A query causes AUTHORITY section to show up but when
    # querying for NS record, only ADDITIONAL shows up (not sure which is
    # right to begin with as we are not really looking for an answer, but
    # gleaning the nameserver names and glue records from the TLD servers)
    my $cmd = "dig $suffix_nameserver_ip A $this_domain." .
        ' +noall +authority +additional +comments';
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
