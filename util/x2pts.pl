#!/usr/bin/perl

# x2pts.pl - converts tetrix winlist to pts format
#
# Copyright 2001-2002 DEQ <deq@oct.zaq.ne.jp>
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License.

use FileHandle;
use strict;

use constant SCOREDECIMAL => 2;

# push(@ARGV, 'game.winlist');

my $suffix = ".pts"; # suffix of new files
my $winlist_type = 1;

if (scalar @ARGV == 0) {
  print "Usage: $0 file...\n";
  exit;
}

while (my $from = shift @ARGV) {
  my $in = FileHandle->new($from, 'r') or die "Could not open the file `$from' to read";
  binmode $in;
  my $out = FileHandle->new("$from$suffix", 'w') or die "Could not open the file `$from$suffix' to write";

  my $buf;
  while ( sysread($in, $buf, 1) ) {
    $buf = unpack('A1', $buf) or last;
    my $prefix = $buf; # `p'layer or `t'eam
    sysread($in, $buf, 31);
    my $nick = unpack('A31', $buf);
    sysread($in, $buf, 4);
    my $points = unpack('L1', $buf);
    $points = round($points, SCOREDECIMAL);
    sysread($in, $buf, 4);
    my $inuse = unpack('I1', $buf); # char?

    print $out "$winlist_type $prefix$nick $points\n";
  }

  close($out);
  close($in);
}

exit;

# source: http://www.din.or.jp/~ohzaki/perl.htm
sub round {
  my ($num, $decimals) = @_;
  my ($format, $magic);
  $format = '%.' . $decimals . 'f';
  $magic = ($num > 0) ? 0.5 : -0.5;
  sprintf($format, int(($num * (10 ** $decimals)) + $magic) /
                   (10 ** $decimals));
}
