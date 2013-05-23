#!/usr/bin/perl

use Data::Dumper;

$my_string = "1 2 3\na b c\nx y z\n";
@my_grid = string_to_grid($my_string);
@offsets = (0, -1);
print grid_to_string(\@my_grid); 
print grid_to_string(\@my_grid, \@offsets); 

sub string_to_grid {
    my $in = shift;
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
        } else {
            foreach (@keepers) {            
               push(@pruned_line, @{$line}[$_]);
            }
        }
        $out .= join(' ', @pruned_line) . "\n";
    }
    return $out;
}

sub uniq2 {
    my %seen = ();
    my @r = ();
    foreach my $a (@_) {
        unless ($seen{$a}) {
            push @r, $a;
            $seen{$a} = 1;
        }
    }
    return @r;
}
