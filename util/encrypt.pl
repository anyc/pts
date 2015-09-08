#!/usr/bin/perl

# encrypt.pl - encrypts your password for writing pts.secure
# You need to run this program on the same machine you want to run pts.pl.
#
# Copyright 2001-2002 DEQ <deq@oct.zaq.ne.jp>
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License.

use strict;

# hiding your input. turn this on if your OS supports.
my $STTYECHO = ($^O eq 'MSWin32' ? 0 : 1);

my $input = shift;

if (not defined $input) {
  system("stty -echo") if $STTYECHO;
  print "password: ";
  chomp($input = <STDIN>);
  system("stty echo") if $STTYECHO;
  print "\n";
}

exit if $input eq '';
(print "No spaces allowed.\n", exit) if $input =~ /\x20/;

srand;
my @set = ('a'..'z', 'A'..'Z', '0'..'9', '/', '.');
my $salt = $set[int(rand(@set))] . $set[int(rand(@set))];
my $encrypted = crypt($input, $salt);
print "$encrypted\n";

exit;
