#!/usr/local/bin/perl

# merge.pl - marges some pts winlist files
#
# Copyright 2001-2002 DEQ <deq@oct.zaq.ne.jp>
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License.

use FileHandle;
use strict;

use constant SCOREDECIMAL => 2;
use constant CS => 0; # case sensitive
use constant DEF_WLTYPE => 1; # default winlist type

# push(@ARGV, 'merged.winlist' => 'game1.winlist', 'game2.winlist');

if (scalar @ARGV < 2) {
  print "Usage: $0 output_file file...\n";
  exit;
}

my $outfile = shift @ARGV;

my @wl = (undef);
while (my $from = shift @ARGV) {
  my $in = FileHandle->new($from, 'r') or die "Could not open the file `$from' to read";
  while (my $line = <$in>) {
    my ($name, $value, $wltype);
    if ($line =~ /^\d/) { # new format (v0.10 or later)
      next unless $line =~ /^(\d+) ([^ ]+) ([0-9.]+)$/;
      ($wltype, $name, $value) = ($1, $2, $3);
    } else { # old format
      next unless $line =~ /^([^ ]+) ([0-9.]+)$/;
      ($name, $value) = ($1, $2);
      $wltype = DEF_WLTYPE;
    }
    my $key = (CS ? $name : lc $name);
    $wl[$wltype] = {} unless defined $wl[$wltype];
    if (defined $wl[$wltype]{$key}) {
      $wl[$wltype]{$key}[2] += $value;
    } else {
      $wl[$wltype]{$key} = [$wltype, $name, $value];
    }
  }
  close($in);
}

my $out = FileHandle->new("$outfile", 'w') or die "Could not open the file `$outfile' to write";
foreach my $winlist (@wl) {
  next unless defined $winlist;
  my @tmp = values %$winlist;
  @tmp = sort {$b->[2] <=> $a->[2]} @tmp;
  foreach (@tmp) {
    my ($wltype, $name, $value) = @$_;
    $value = round($value, SCOREDECIMAL);
    print $out "$wltype $name $value\n";
  }
}
close($out);

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
