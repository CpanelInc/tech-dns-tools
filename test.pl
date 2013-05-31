#!/usr/bin/perl

use Data::Dumper;

$x = 'a.b.c';
print split('\.', $x)[-1];
print "\n";
