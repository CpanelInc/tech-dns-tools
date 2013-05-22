#!/usr/bin/perl

use Data::Dumper;

$lines = ";; AUTHORITY SECTION:
barrioearth.com.	172800	IN	NS	ns1.linode.com.
barrioearth.com.	172800	IN	NS	ns2.linode.com.
barrioearth.com.	172800	IN	NS	ns3.linode.com.

;; ADDITIONAL SECTION:
ns1.linode.com.		172800	IN	AAAA	2600:3c00::a
ns1.linode.com.		172800	IN	A	69.93.127.10
ns2.linode.com.		172800	IN	AAAA	2600:3c01::a
ns2.linode.com.		172800	IN	A	65.19.178.10";

#print $lines;
my $x = lines_between_strings($lines, ';;', '');
my @cols = (0, -1);
$x = show_columns($x, '\s', \@cols);
print $x;

sub show_columns {
    my $input = $_[0];
    my $delimiter = $_[1];
    my @columns_to_show = @{$_[2]};
    my $separator = ' ';
    my $result = '';
    for (split /^/, $input) {
        my @parts = split($delimiter, $_);
        for ($i = 0; $i < $#columns_to_show + 1; $i++) {
            $result .= $separator if $result && $i < $#columns_to_show + 1;
            if ($parts[$columns_to_show[$i]]) {
                $result .= $parts[$columns_to_show[$i]];
            }
        }
        $result .= "\n";
    }
    return $result . "\n";
}

sub lines_between_strings {
    my $input = shift;
    my $start_pattern = shift;
    my $end_pattern = shift;
    my $result;
    for (split /^/, $input) {
        if (/^$start_pattern/../^$end_pattern$/) {
            next if /^$start_pattern/ || /^$end_pattern$/;
            $result .= "$_";
        }
    }
    return $result . "\n";
}
