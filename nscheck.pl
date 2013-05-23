#!/usr/bin/perl
#use 5.008008;
use strict;
use warnings;

use Data::Dumper;

my $domain = shift(@ARGV);
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
    $module_available{$_} = import_module_if_found($_);
}

# DEBUG START # pretend certain modules are not available
$module_available{'Domain::PublicSuffix'} = 1;
$module_available{'Net::DNS'} = 1;
$module_available{'LWP::Simple'} = 1;
#print Dumper(%module_available);exit;
# DEBUG END #

# Globals
my $root_domain;
my @suffixes_to_query;
my $effective_tld_names_file = '/tmp/effective_tld_names.dat';
my $debug = 0;
my $verbose = 0;
my $brief = 0;
my $ipv6 = 0;

# Options interdependencies
if ($debug) {
    $verbose = 1;
    $ipv6 = 1;
    $brief = 0;
}
elsif ($verbose) {
    $brief = 0;
}

# Download effective_tld_names.dat
if ($module_available{'LWP::Simple'}) {
    if (-M $effective_tld_names_file > 7) { # Download if a week old or more
        my $url = 'http://mxr.mozilla.org/mozilla-central/source/netwerk' .
            '/dns/effective_tld_names.dat?raw=1';
        getstore($url, $effective_tld_names_file);
    }
}

# Use Domain::PublicSuffix if available to determine public suffix, also called
# "effective TLD".
if ($module_available{'Domain::PublicSuffix'}) {
    my $public_suffix = Domain::PublicSuffix->new({
        'data_file' => $effective_tld_names_file
    });
    $root_domain = $public_suffix->get_root_domain($domain);

    if ( $public_suffix->error ) {
        printf( "%12s: %s\n", 'Error', $public_suffix->error );
        exit(1);
    }
    else {
        push(@suffixes_to_query, $public_suffix->suffix);
        if ($public_suffix->tld ne $public_suffix->suffix) {
            push(@suffixes_to_query, $public_suffix->tld);
        }
    }    
}
# If Domain::PublicSuffix is not available, figure out suffixes using
# downloaded database file
else {
    my $tld = $domain_parts[-1];
    my $etld = join('.', @domain_parts[-2..-1]);
    if (-e $effective_tld_names_file) {
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

unless ($brief) {
    print $hr_bold;
    printf("%15s: %s\n", 'Domain', $domain);
    printf("%15s: %s\n", 'Root domain', $root_domain );
    printf("%15s: %s\n", 'Public suffix', $suffixes_to_query[0]);
    printf("%15s: %s", 'TLD', $suffixes_to_query[1]);
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
    printf("%s\n", 'TLD Servers:') unless $brief;
    my @ips;
    for (my $j = 0; $j < $#names + 1; $j++) {
        my $name = $names[$j];
        my $ip = a_lookup($name);
        push(@ips, $ip) if $ip;
        printf("%-23s %s\n", $name, $ip) unless $brief;
    }
    if (@ips) {
        # Ask the TLD servers for authoritative nameservers of domain
        print suffix_nameserver_report($root_domain, \@ips) . "\n";
    }
    else {
        print 'Error! None of the nameservers for the suffix "' .
            " ${suffixes_to_query[$i]}\" resolve to an IP address.\n";
    }
}

sub get_nameservers {
    my $this_domain = shift;
    if ($module_available{'Net::DNS'}) {
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
    if ($module_available{'Net::DNS'}) {
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
        warn("query failed: \`$cmd\`") if $debug;
        return '';
    }
    my @answers = split(/\n/, $result);
    return $answers[0] || '';
}

sub suffix_nameserver_report {
    my $this_domain = $_[0];
    my @suffix_nameserver_ips = @{$_[1]};
    if ($module_available{'Net::DNS'}) {
        return suffix_nameserver_report_Net_Dns($this_domain,
            \@suffix_nameserver_ips);
    }
    return suffix_nameserver_report_dig($this_domain, \@suffix_nameserver_ips);
}

sub suffix_nameserver_report_Net_Dns {
    my $this_domain = $_[0];
    my @suffix_nameserver_ips = @{$_[1]};
    my $res = Net::DNS::Resolver->new(
        nameservers => [(@suffix_nameserver_ips)],
        recurse => 0,
      	debug => 0,
    );
    # TODO: Should this be an A query, or NS, or what?
    my $packet = $res->send("${this_domain}.", 'A');
    my @authority = $packet->authority;
    my @additional = $packet->additional;
    my $result = "\nAUTHORITY:\n";
    foreach my $rr (@authority) {
        $result .= $rr->string . "\n";
    }
    $result .= "\nADDITIONAL:\n";
    foreach my $rr (@additional) {
        next if ! $ipv6 && $rr->string =~ /AAAA/;
        $result .= $rr->string . "\n";
    }
    return $result . "\n";
}

# TODO: randomize which nameserver is used since this script currently
# always uses the same nameserver
sub suffix_nameserver_report_dig {
    my $this_domain = $_[0];
    my @suffix_nameserver_ips = @{$_[1]};
    # TODO: find out why A query causes AUTHORITY section to show up but when
    # querying for NS record, only ADDITIONAL shows up (not sure which is
    # right to begin with as we are not really looking for an answer, but
    # gleaning the nameserver names and glue records from the TLD servers)
    my $cmd = "dig \@$suffix_nameserver_ips[0] A $this_domain." .
        ' +noall +authority +additional +comments';
    chomp(my $verbose_result = qx($cmd));
    unless ($verbose) {
        my $dig_output_filter = '';
        $dig_output_filter = $ipv6 ? '' : 'AAAA';
        my $authority_raw = lines_between_strings($verbose_result,
            ';; AUTHORITY', '');
        my $additional_raw = lines_between_strings($verbose_result,
            ';; ADDITIONAL', '', $dig_output_filter);
        my @authority_grid = string_to_grid($authority_raw);
        my @additional_grid = string_to_grid($additional_raw);
        my @offsets_to_show = (-1);
        my $authority_result = grid_to_string(\@authority_grid,
            \@offsets_to_show);
        @offsets_to_show = (0, -1);
        my $additional_result = grid_to_string(\@additional_grid,
            \@offsets_to_show);
        my $result = '';
        $result .= "\nNameservers:\n$authority_result" if $authority_result;
        $result .= "\nGlue records:\n$additional_result" if $additional_result;
        return $result;
    }
    return $verbose_result;
}

sub string_to_grid {
    chomp(my $in = shift);
    my @out;
    for (split /^/, $in) {
        my @row = split(/\s+/, $_);
        push(@out, \@row);
    }
    return @out;
}

sub grid_to_string {
    my @lines = @{$_[0]};
    my @keepers = @{$_[1]};
    my $out;
    foreach my $line (@lines) {
        my @pruned_line;
        unless (@keepers) {
            @pruned_line = @{$line};
        }
        else {
            foreach (@keepers) {            
               push(@pruned_line, @{$line}[$_]);
            }
        }
        my $formatted_line = sprintf(
            "%-24s" x ($#pruned_line + 1) . "\n",
            @pruned_line
        );
        $out .= $formatted_line;
    }
    return $out;
}

sub lines_between_strings {
    my $input = shift;
    my $start_pattern = shift;
    my $end_pattern = shift;
    my $filter_pattern = shift;
    my $result;
    for (split /^/, $input) {
        if (/^$start_pattern/../^$end_pattern$/) {
            next if /^$start_pattern/ || /^$end_pattern$/;
            if ($filter_pattern) {
                next if /$filter_pattern/;
            }
            $result .= "$_";
        }
    }
    return $result . "\n";
}

sub usage {
	my ( $error ) = @_;
	print "Usage: nscheck <domainname>\n";
	exit(1);
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

1;
