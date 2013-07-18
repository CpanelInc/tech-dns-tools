#!/usr/bin/perl

# TODO:
# - Show dig command in NS query like already doing in TLD report
# - Explicitly check whether NS servers are different than servers reported by
#   the TLD servers. If so, query both independently to show differences
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
my @possible_suffixes;
my $etld_database_file = '/tmp/effective_tld_names.dat';
my $hr_bold = "\n" . '#' x 50 . "\n";
my $hr = "\n" . '-' x 50 . "\n";

# Default options
%options = (
    'brief'         => 0,
    'check-all'     => 0,
    'debug'         => 0,
    'dig',          => 0,
    'help'          => 0,
    'ipv6'          => 0,
    'manual'        => 0,
    'net-dns',      => 1,
    'public-suffix' => 1,
    'show-auth'     => 1,
    'show-servers'  => 0,
    'sort'          => 0,
    'verbose'       => 0,
    'version'       => 0
);

# Process command line arguments
process_args();

sub process_args {
    Getopt::Long::GetOptions(
        'brief',          \$options{'brief'},
        'check-all',        \$options{'check-all'},
        'debug',            \$options{'debug'},
        'dig',              \$options{'dig'},
        'help',             \$options{'help'},
        'ipv6',             \$options{'ipv6'},
        'manual',           \$options{'manual'},
        'public-suffix',    \$options{'public-suffix'},
        'show-auth',     \$options{'show-auth'},
        'show-servers',     \$options{'show-servers'},
        'sort',     \$options{'sort'},
        'verbose',        \$options{'verbose'},
        'version',          \$options{'version'}
    ) or Pod::Usage::pod2usage(2);

    # Options interdependencies
    if ($options{'debug'}) {
        $options{'verbose'}         = 1;
        $options{'ipv6'}            = 1;
        $options{'show-servers'}    = 1;
        $options{'brief'}           = 0;
    }
    elsif ($options{'verbose'}) {
        $options{'brief'}           = 0;
    }
    if ($options{'check-all'}) {
        $options{'show-servers'}    = 1;
    }
    if ($options{'dig'}) {
        $options{'net-dns'}         = 0;
    }

    $domain = $ARGV[0] || '';
    $domain =~ s/[\.]+$//; # Remove any trailing dots
    @domain_parts = split(/\./, $domain);
    $tld = $domain_parts[-1];
    $etld = $tld; # Default value, may change

    $options{'help'} = 1 unless $domain && $tld;

    if (!$options{'version'} and ($options{'manual'} or $options{'help'})) {
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
        exit if $options{'version'};
    }
}

# Conditionally use certain modules
# - Domain::PublicSuffix - derive root domain and effective TLD.
# - Net::DNS - perform DNS queries
# - LWP::Simple - perform simple web requests
my @modules = ('Domain::PublicSuffix', 'Net::DNS', 'LWP::Simple');
my %module_available;
foreach (@modules) {
    next if $_ eq $options{'dig'} and $_ == 'Net::DNS';
    next if $_ eq $options{'public-suffix'} and $_ == 'Domain::PublicSuffix';
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
    unless (-e $etld_database_file and -M $etld_database_file < 7) {
        my $url = 'http://mxr.mozilla.org/mozilla-central/source/netwerk' .
            '/dns/effective_tld_names.dat?raw=1';
        getstore($url, $etld_database_file);
    }
}

# Use Domain::PublicSuffix if available to determine the domain's "public
# suffix", also called "effective tld" or "etld".
if ($options{'public-suffix'} and $module_available{'Domain::PublicSuffix'}) {
    my $public_suffix = Domain::PublicSuffix->new({
        'data_file' => $etld_database_file
    });
    $root_domain = $public_suffix->get_root_domain($domain);

    if ( $public_suffix->error ) {
        printf( "%12s: %s\n", 'Error', $public_suffix->error );
        exit(1);
    }
    else {
        $tld = $public_suffix->tld;
        $etld = $public_suffix->suffix;
        push(@possible_suffixes, $etld);
        push(@possible_suffixes, $tld) if $tld ne $etld;
    }
}

# If Domain::PublicSuffix is not available, figure out suffixes using
# downloaded database file
else { 
    if (-e $etld_database_file) {
        my $domain_parts_offset = 2;
        open SUFFIX_FILE, '<', $etld_database_file;
        LINE:
        while (<SUFFIX_FILE>) {
            if (/^\/\/ $tld/../^$/) {
                next LINE if /^\/\// or /^$/;
                chomp ( my $this_suffix = $_ );

                # Loop through possible public suffixes. First match is
                # treated as the etld
                DOMAIN_PART:
                for $domain_parts_offset (2..scalar @domain_parts) {
                    my $possible_suffix = join('.',
                        @domain_parts[-$domain_parts_offset..-1]);
                    if ($possible_suffix eq $this_suffix) {

                        # Assume that etld is the first suffix that is not the tld
                        $etld = $this_suffix;
                        unshift(@possible_suffixes, $possible_suffix); 
                        last DOMAIN_PART; # Break out of loop since there should only ever
                               # be one match, which is the etld
                    }
                }
            }
        }
        # Rebuild root domain from parts
        $root_domain = $domain_parts[-$domain_parts_offset - 1] . '.' . $etld;
        push(@possible_suffixes, $tld);
    }
    # No public suffix database file
    else {
        $root_domain = $domain; # Assume user provided root domain
        if (scalar @domain_parts > 3) { # Prune to 3 parts maximum
            @domain_parts = @domain_parts[-3..-1];
        }
        if (scalar @domain_parts > 2) { # If 3 parts, assume 2-part etld
            $etld = join('.', @domain_parts[-2..-1]);
        }
        push(@possible_suffixes, $etld);
        push(@possible_suffixes, $tld) if $tld ne $etld;

        # Remove any subdomain parts that still remain in root domain
        $root_domain =~ s/\.$etld//;
        my @stem_parts = split(/\./, $root_domain);
        $root_domain = $stem_parts[-1] . '.' . $etld;
    }
#    $root_domain =~ s/\.$etld//;
#    my @stem_parts = split(/\./, $root_domain);
#    $root_domain = $stem_parts[-1] . '.' . $etld;
}

unless ($options{'brief'}) {
    print $hr_bold;
    printf("%15s: %s\n", 'Domain', $domain);
    printf("%15s: %s\n", 'Root domain', $root_domain );
    printf("%15s: %s\n", 'Public suffix', $etld);
    printf("%15s: %s", 'True TLD', $tld);
    print $hr_bold;
}

print "\n";

SUFFIX: # Get nameservers for the effective tld and the true tld
for (my $i = 0; $i < $#possible_suffixes + 1; $i++) {
    my $suffix = $possible_suffixes[$i];
    printf("%s: %s\n", '-=-= Suffix:', ${suffix});
    my @names = get_nameservers($suffix);
    unless (scalar @names) {
        print "No nameservers found for this suffix.\n\n";
        next SUFFIX;
    }
    printf("%s\n", 'Suffix servers:') if $options{'show-servers'};

    A_LOOKUP:
    my @suffix_servers;
    for (my $j = 0; $j < $#names + 1; $j++) {
        my $name = $names[$j];
        my $ip = a_lookup($name);
        if ($ip) {
            printf("%-23s %s\n", $name, $ip) if $options{'show-servers'};
            my %pair = ( 'name' => $name, 'ip' => $ip );
            push(@suffix_servers, \%pair);
        }
    }
    print "\n" if $options{'show-servers'};
    unless (@suffix_servers) {
        print 'Error! None of the nameservers for the suffix"' .
            " ${possible_suffixes[$i]}\" resolve to an IP address.\n";
    }
    else {
        PRUNE_SUFFIX: # Query just one server unless check-all enabled
        unless ($options{'check-all'}) {
            my $high = scalar @suffix_servers;
            my $random_offset = 0 + int rand($high - 1);
            @suffix_servers = ($suffix_servers[$random_offset]);
        }

        IP: # Ask the TLD servers for authoritative nameservers of domain
        foreach my $server (@suffix_servers) {
            my %suffix_server = %{$server};
            my $ip = $suffix_server{'ip'};
            my $name = $suffix_server{'name'};
            if ($options{'verbose'} or scalar @suffix_servers > 1) {
                print $hr if scalar @suffix_servers > 1;
                print "Querying $name ($ip)...\n";
            }
            print suffix_nameserver_report($root_domain, $ip);
        }
        print "\n";
    }
}

# Show nameservers according to NS query
if ($options{'show-auth'}) {
    print "Nameservers according to NS query:\n";    
    show_ns_records($root_domain);
}

# TODO: query authoritative nameservers directly
sub show_ns_records {
    my $domain = shift;
    my @ns_server_names = dns_lookup('NS', $domain);
    my %ns_servers; # Hash allows for later sorting
    foreach my $name (@ns_server_names) {
        my @ips = dns_lookup('A', $name);
        $ns_servers{$name} = \@ips;
    }
    if ($options{'sort'}) {
        foreach my $key (sort(keys %ns_servers)) {
            print $key;
            foreach my $ip (@{$ns_servers{$key}}) {
                print '   ' . $ip;
            }
            print "\n";
        }
    }
    else {
        keys %ns_servers; # reset the internal iterator
        while(my($k, $v) = each %ns_servers) {
            print $k;
            foreach my $ip (@$v) {
                print '   ' . $ip;
            }
            print "\n";
        }
    }
}

sub get_nameservers {
    my $domain = shift;
    if (! $options{'dig'} and $module_available{'Net::DNS'}) {
        return get_nameservers_Net_Dns($domain);
    }
    return get_nameservers_dig($domain);
}

sub get_nameservers_Net_Dns {
    my $domain = shift;
    my $res = Net::DNS::Resolver->new;
    my $query = $res->query("${domain}.", 'NS');
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
    my $domain = shift;
    my $cmd = "dig NS \@8.8.8.8 ${domain}. +short";
    chomp( my $result = qx($cmd) );
    unless ($result) {
        warn("query failed: \`$cmd\`");
        return;
    }
    $result =~ s/\.$//;
    return unless $result;
    return split(/\.\n/, $result);
}

sub dns_lookup {
    my $type = shift;
    my $domain = shift;
    if (! $options{'dig'} and $module_available{'Net::DNS'}) {
        return dns_lookup_Net_Dns($type, $domain);
    }
    return dns_lookup_dig($type, $domain);
}

sub dns_lookup_Net_Dns {
    my $type = shift;
    my $domain = shift;
    $type = uc($type);
    my $res = Net::DNS::Resolver->new;
    my $query = $res->query("${domain}.", $type);
    my @answers;
    if ($query) {
        foreach my $rr (grep { $_->type eq $type } $query->answer) {
            if ($type eq 'A') {
                push(@answers, $rr->address);
            }
            else {
                push(@answers, $rr->nsdname);
            }
        }
    }
    else {
        warn "query failed: ", $res->errorstring, "\n";
    }
    return @answers;
}

sub dns_lookup_dig {
    my $type = shift;
    my $domain = shift;
    $domain =~ s/\.$//;
    $type = uc($type);
    my $cmd = "dig ${type} \@8.8.8.8 ${domain}. +short";
    print "$cmd\n" if $options{'debug'};
    chomp( my $result = qx($cmd) );
    unless ($result) {
        warn("query failed: \`$cmd\`");
        return '';
    }
    my @answers = split(/\n/, $result);
    return @answers;
}


sub a_lookup {
    my $domain = shift;
    my @ips = dns_lookup('A', $domain);
    return $ips[0];
}

sub suffix_nameserver_report {
    my $domain = shift;
    my $ip = shift;
    my $result = '';
    my $sections = '';
    if ($module_available{'Net::DNS'} and ! $options{'dig'}) {
        $sections = nameserver_sections_from_Net_DNS($domain, $ip);
    } else {
        $sections = nameserver_sections_from_dig($domain, $ip);
    }
    $result .= nameserver_section_to_text(\@{$sections->{'authority'}},
            'authority') . "\n\n" .
        nameserver_section_to_text(\@{$sections->{'additional'}},
            'additional') . "\n";
    return $result;
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
    my $domain = shift;
    my $ip = shift;
    my $res = Net::DNS::Resolver->new(
        nameservers => [($ip)],
        recurse => 0,
      	debug => 0,
    );
    my $packet = $res->send("${domain}.", 'A');
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

sub nameserver_section_to_text {
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

    ROW:
    foreach my $line_hash (@input) {
        next ROW if $line_hash->{'type'} eq 'AAAA' and ! $options{'ipv6'};

        COLUMN:
        my @line_array;
        my $line = '';
        foreach my $column_name (@{$format->{$section}->{'columns'}}) {
            if ($line_hash->{$column_name}) {
                push(@line_array, $line_hash->{$column_name});
            }
        }
        if (@line_array) {
            $line = join('   ', @line_array);
        }
        push(@out, $line) if $line;
    }
    push(@out, 'No results found') unless scalar @out;
    unshift(@out, $format->{$section}->{'header'});
    return join("\n", @out);
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
    LINE:
    foreach (@input) {
        next if /SOA/;
        my %line_hash;
        my @column_values = split(/\s+/, $_);
            COLUMN:
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
            next if /^$start_pattern/ or /^$end_pattern$/;
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
__END__

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

=over 16

=item B<--brief>

Show brief output

=item B<--check-all>

Instead of querying just one suffix server, iterate through all servers,
querying each one in turn

=item B<--debug>

Show debugging messages

=item B<--dig>

Use dig to perform DNS queries

=item B<--help>

Show the help information

=item B<--ipv6>

Show ipv6 records in output

=item B<--manual>

Read the manual, with examples.

=item B<--net-dns>

Use Net::DNS perl module to perform DNS queries (default)

=item B<--show-servers>

List the suffix servers for the corresponding suffix

=item B<--verbose>

Show verbose output

=item B<--version>

Show the version number and exit

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
