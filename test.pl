#!/usr/bin/perl

use Data::Dumper;

my @x = ('a', 'b');
foreach (@x) {
    next unless /^a$/ or /^[ab]$/; print $_ . "\n";
}
