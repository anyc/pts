#!/usr/bin/perl

# pts2x.pl - converts pts winlist to tetrix format
#
# Copyright 2001-2002 DEQ <deq@oct.zaq.ne.jp>
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License.

use FileHandle;
use strict;

# push(@ARGV, 'game.winlist');

my $suffix = ".x"; # suffix of new files

if (scalar @ARGV == 0) {
  print "Usage: $0 file...\n";
  exit;
}

while (my $from = shift @ARGV) {
  my $in = FileHandle->new($from, 'r') or die "Could not open the file `$from' to read";
  my $out = FileHandle->new("$from$suffix", 'w') or die "Could not open the file `$from$suffix' to write";
  binmode $out;

  while (my $line = <$in>) {
    my ($name, $value);
    if ($line =~ /^\d/) { # new format (v0.10 or later)
      next unless $line =~ /^(\d+) ([^ ]+) ([0-9.]+)$/;
      ($name, $value) = ($2, $3);
    } else { # old format
      next unless $line =~ /^([^ ]+) ([0-9.]+)$/;
      ($name, $value) = ($1, $2);
    }
    $name = pack('a32', $name);
    my $points = pack('L1', abs int $value);
    my $inuse = pack('I1', 1); # char?

    print $out "$name$points$inuse";
  }

  close($out);
  close($in);
}
