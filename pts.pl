#!/usr/local/bin/perl

# =================================================================
#   Perl TetriNET Server v0.20
#                                       Copyright 2001-2002 DEQ
#
#   E-Mail: deq@oct.zaq.ne.jp
#   Web: http://www.necoware.com/~deq/tetrinet/pts/
# =================================================================
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License.
#
# -----------------------------------------------------------------

use constant VERSION => '0.20';
use constant DEBUG => 0;

use Config::IniFiles;
use English;
use IO::Select;
use IO::Socket;
use POSIX qw();
use strict;

# path
use constant BANFILE => "./pts.ban"; # ban list file
use constant BACKUPSUFFIX => ".old"; # winlist old data file suffix
use constant CONFIGFILE => "./pts.ini"; # config file
use constant DAILYFILE => "./dstats/%y%m.log"; # daily stats file (%y = year, %m = month, %d = month day)
use constant LMSGFILE => "./pts.lmsg"; # left message file
use constant LOGFILE => "./logs/%y%m.log"; # log file (%y = year, %m = month, %d = month day)
use constant PIDFILE => "./pts.pid"; # pid file
use constant PROFILEFILE => "./pts.profile"; # profile file
use constant RELAUNCH => "perl $PROGRAM_NAME"; # shell command to re-launch the server
use constant SECUREFILE => "./pts.secure"; # secure (password) file

# system
use constant DAEMON => 0; # run as daemon (fork() should be available)
                          # windows perl user should set this off
use constant NOFORK => 0; # no using fork()
                          # fork() doesn't work on some operating systems
use constant TIMEHIRES => 0; # use Time::HiRes perl module to get millisecond resolution time
                             # you may need to install the module to use this

# common
use constant AUTOSAVE => 600; # writes out profile/winlist/etc data to file per this seconds
use constant CHANNELPREFIX => '#'; # channel name prefix
use constant CLOCKCHANGED => 3; # if this seconds are over than just before, consider that inner clock has been changed
use constant COMMANDPREFIX => '/'; # partyline command prefix
use constant GMSGPAUSE => 'p'; # game message(gmsg) to be intercepted for game pause/unpause
use constant GMSGPING => 't'; # game message(gmsg) to be intercepted for ping
use constant GMSGPONG => '* PONG'; # reply message for gmsg ping
use constant MAXCHANNELLENGTH => 16; # max channel name length
use constant MAXMESSAGELENGTH => 1024; # max one row protocol message length
use constant MAXNICKLENGTH => 30; # max nick name length
use constant MAXSDMSGLENGTH => 512; # max sudden death message length
use constant MAXSTARTINGCOUNT => 10; # max starting count
use constant MAXSTACKLEVEL => 1;
use constant MAXTEAMLENGTH => 30; # max team name length
use constant MAXTOPICLENGTH => 256; # max channel topic length
use constant PINGAVE => 10; # number of ping times saved for average
use constant SCOREDECIMAL => 2;
use constant SHUTDOWNWAITTIME => 10; # shut down wait time
use constant STARTINGCOUNTINTERVAL => 1; # starting count interval (seconds)

# network
use constant LISTENQUEUESIZE => SOMAXCONN; # listen queue size
use constant PROTOCOLVERSION => '1.13'; # version of the tetrinet protocol
use constant RCHUNKSIZE => 1024; # chunk size reading from socket
use constant SELECTINTERVAL => 0.1; # select() interval
use constant TERMINATOR => "\xFF"; # message terminator of the tetrinet protocol
use constant QUERYTERMINATOR => "\x0A";
use constant TNETPORT => 31457; # port for tetrinet client
use constant WCHUNKSIZE => 512; # chunk size writing to socket
use constant LOCALHOST => '127.0.0.1'; # 'localhost' or '127.0.0.1' (IPv4)

# DNS lookup
use constant LOOKUPHOST => 1; # lookup host name or not
use constant LOOKUPPORT => 31462; # port for lookup
use constant LOOKUPTIMEOUT => 6; # lookup timeout (seconds)
use constant LOOKUPEXPIRE => 150; # lookup hostname expire (minutes)

# misc - recommended not to edit
use constant MAXPLAYERS => 6; # TetriNET client's max number of players
use constant FIELD_WIDTH => 12;
use constant FIELD_HEIGHT => 22;
use constant BLOCKS => [qw(0 1 2 3 4 5 a c n r s b g q o)];

use constant CONNECTION_TETRINET => 'tetrinet';
use constant CONNECTION_LOOKUP => 'lookup';
use constant CLIENT_TETRINET => 'tetrinet';
use constant CLIENT_TETRIFAST => 'tetrifast';
use constant CLIENT_QUERY => 'query';
use constant HELLOMSG_TETRINET => 'tetrisstart';
use constant HELLOMSG_TETRIFAST => 'tetrifaster';

use constant BAN_RAW => 0;
use constant BAN_MASK => 1;

use constant PF_P => 0;
use constant PF_PNAME => 0;
use constant PF_PALIAS => 1;
use constant PF_PPASSWORD => 2;
use constant PF_PAUTHORITY => 3;
use constant PF_PTEAM => 4;
use constant PF_PLOCALE => 5;
use constant PF_PLOGINS => 6;
use constant PF_PLASTLOGIN => 7;
use constant PF_PONLINETIME => 8;
use constant PF_PGAMES => 9;

use constant VERIFY_FIELDCHANGES => 13;
use constant VERIFY_STRICT => {
                    # each time,  total
  CLIENT_TETRINET()  => [0, 2,   12, 15],
  CLIENT_TETRIFAST() => [0, 1,    1,  3],
};
use constant VERIFY_LOOSE => {
                    # each time,  total
  CLIENT_TETRINET()  => [0, 3,   11, 18],
  CLIENT_TETRIFAST() => [0, 1,    1,  5],
};

use vars qw(
  $Config %Msg @Ban @Profiles %Users @Channels @Winlist %Lmsg %Daily %Misc
  @COLOR_CODES @COLOR_NAMES
);

StartServer();
MainLoop();

exit;

sub MainLoop {
  for (;;) {
    my @ready = IO::Select->select($Misc{readable}, $Misc{writable}, undef, SELECTINTERVAL);

    foreach my $s ( @{$ready[1]} ) { # writable sockets
      my $msg = (defined $Misc{closing}{$s} ? $Misc{closing}{$s} : $Users{$s}{sendbuf} );
      my $wrote = syswrite($s, $msg, WCHUNKSIZE);
      CheckBrokenpipe($s);
      if (not $wrote) {
        CloseClosingConnection($s);
        next;
      }
      $msg = substr($msg, $wrote);
      defined $Misc{closing}{$s} ? $Misc{closing}{$s} = $msg : $Users{$s}{sendbuf} = $msg;
      if ($msg eq '') {
        $Misc{writable}->remove($s);
        CloseClosingConnection($s);
      }
    }

    foreach my $s ( @{$ready[0]} ) { # readable sockets
      if ($s == $Misc{listener}{tetrinet}) { # new connection from tetrinet client
        my $new = $Misc{listener}{tetrinet}->accept();
        if (defined $new) {
          binmode $new;
          $Misc{clients}{$new} = {socket => $new, type => CONNECTION_TETRINET};
          my $ip = $new->peerhost();
          $Users{$new} = {InitialUserData(), socket => $new, ip => $ip};
          LOOKUPHOST ? LookupHost($new) : SetHost($new, '');
        } else {
          Report('debug', undef, undef, "DEBUG: accept() failed");
        }
      } elsif ($s == $Misc{listener}{lookup}) { # new connection from lookup client
        my $new = $Misc{listener}{lookup}->accept();
        if (defined $new) {
          binmode $new;
          $Misc{readable}->add($new);
          $Misc{clients}{$new} = {socket => $new, type => CONNECTION_LOOKUP};

          my $ip = $new->peerhost();
          Report('lookup', $new, $new, "New Connection $ip [lookup]");
        } else {
          Report('debug', undef, undef, "DEBUG: accept() failed");
        }
      } else { # existing client connection
        my $cltype = $Misc{clients}{$s}{type};

        my $buf;
        my $read = sysread($s, $buf, RCHUNKSIZE);
        if ($read) {
          if ($cltype eq CONNECTION_TETRINET) {
            # update last response time
            $Users{$s}{timeout} = PTime();
            $Users{$s}{timeoutpinged} = undef;
            UpdateTimeoutIngame($s);
            UpdateGameStatsLast($s);
            $Users{$s}{idletime} = PTime() if (scalar @{$Users{$s}{playernum}} == 0);

            my $term = TERMINATOR;
            my @bufs = split(/$term/, $buf);
            $bufs[0] = $Users{$s}{recvbuf} . (defined $bufs[0] ? $bufs[0] : '');
            $Users{$s}{recvbuf} = '';
            $Users{$s}{recvbuf} = pop(@bufs) if substr($buf, -(length $term)) ne $term;
            if ( length $Users{$s}{recvbuf} > MAXMESSAGELENGTH ) {
              Report('connection_error', $s, $s, RMsgDisconnect("Too long message ($Users{$s}{recvbuf})", $s));
              CloseConnection($s);
              next;
            }
            foreach (@bufs) {
              TetrinetMessage($s, $_) if $_ ne '';
            }
          } elsif ($cltype eq CONNECTION_LOOKUP) {
            my $term = TERMINATOR;
            if ( substr($buf, -(length $term)) eq $term ) {
              my $msg = substr($buf, 0, length($buf) - length($term));
              LookupMessage($s, $msg) if $msg ne '';
            } else {
              Report('debug', undef, $s, "DEBUG: Broken message from lookup client ($buf)");
            }
          } else {
            Report('debug', undef, $s, "DEBUG: Received message from uninitialized client");
          }
        } else { # connection broken
          if ($cltype eq CONNECTION_TETRINET) {
            if ($Users{$s}{client} eq CLIENT_QUERY) {
              Report('query', $s, $s, RMsgDisconnect("EOF from client", $s));
            } else {
              if ( IsCheckingClient($s) ) {
                Report('connection_error', $s, $s, RMsgDisconnect("Disconnected on checking client", $s));
              } else {
                Report('connection', $s, $s, RMsgDisconnect("EOF from client", $s));
              }
            }
          } elsif ($cltype eq CONNECTION_LOOKUP) {
            Report('lookup', $s, $s, "EOF from client");
          } else {
            Report('debug', undef, $s, "DEBUG: EOF from uninitialized client");
          }
          CloseConnection($s);
        }
      }
    }

    my $time = Time();
    my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime($time);
    if ($time != $Misc{lastcheck}[0]) { # do once per second
      IncreasePTime();
      ClockChanged($Misc{lastcheck}[0], $time) if (abs($time - $Misc{lastcheck}[0]) >= CLOCKCHANGED);

      CheckShutdown();
      CheckWaitingLookup();
      foreach my $player (values %Users) {
        next unless defined $player;
        UpdateAntiFlood($player);
        CheckTimeoutOutgame($player);
        CheckTimeoutIngame($player);
      }
      foreach my $ch (@Channels) {
        CheckStartingCount($ch);
        CheckSuddenDeath($ch);
      }

      $Misc{lastcheck}[0] = $time;
    }
    if ($min != $Misc{lastcheck}[1]) { # do once per minute
      CheckLookupExpire();
      CheckBanExpire();
      foreach my $player (values %Users) {
        next unless (defined $player and defined $player->{profile});
        $player->{profile}[PF_PONLINETIME]++;
      }

      $Misc{lastcheck}[1] = $min;
    }
    if ($hour != $Misc{lastcheck}[2]) { # do once per hour
      $Misc{lastcheck}[2] = $hour;
    }
    if ($mday != $Misc{lastcheck}[3][0]) { # do once per day
      WriteDaily($Misc{lastcheck}[3][1]);
      ReadDaily(1);

      @{$Misc{lastcheck}[3]} = ($mday, $time);
    }
    if (AUTOSAVE > 0 and PTime() > $Misc{lastcheck}[4] + AUTOSAVE) { # do once per AUTOSAVE
      WriteProfile();
      WriteWinlist();
      WriteLmsg();
      WriteDaily($time);

      $Misc{lastcheck}[4] = PTime();
    }
  }
}

sub CloseConnection {
  my ($s) = @_;

  my $cltype = $Misc{clients}{$s}{type};
  if ($cltype eq CONNECTION_TETRINET) {
    LeaveChannel($s, undef);
    GarbageChannel($Users{$s}{channel});

    if ($Users{$s}{sendbuf} ne '') {
      $Misc{closing}{$s} = $Users{$s}{sendbuf};
      delete $Users{$s};
      $Misc{readable}->remove($s);
    } else {
      delete $Users{$s};
      CloseSocket($s);
    }
  } elsif ($cltype eq CONNECTION_LOOKUP) {
    CloseSocket($s);
  } else {
    CloseSocket($s);
  }
  SetDailyNowplayers();
}

sub CloseClosingConnection {
  my ($s) = @_;
  return unless defined $Misc{closing}{$s};

  delete $Misc{closing}{$s};
  CloseSocket($s);
}

sub CloseSocket {
  my ($s) = @_;

  delete $Misc{clients}{$s};
  $Misc{readable}->remove($s);
  $Misc{writable}->remove($s);
  $s->close();
  undef $s;
}

# =================================================================
#     Tetrinet protocol functions
# =================================================================

sub TetrinetMessage {
  my ($s, $msg) = @_;
  return unless defined $Users{$s};

  $msg = StripCodes($msg);
  return if $msg eq '';

  Report('raw_receive', undef, $s, "Recv: $msg");
  my ($cmd, $args) = split(/ /, $msg, 2);

  if ($Users{$s}{nick} eq '') {
  # received command should be init command
    if ( substr($msg, 0, 1) =~ /^[A-F0-9]$/ ) {
    # handling encrypted message
      my $decmsg = undef;
      if ( $decmsg = tnet_decrypt($msg, HELLOMSG_TETRINET) ) {
        OnTetrisstart($s, $decmsg);
      } elsif ( $decmsg = tnet_decrypt($msg, HELLOMSG_TETRIFAST) ) {
        OnTetrisstart($s, $decmsg);
      } else {
        Report('connection_error', $s, $s, RMsgDisconnect("Unknown message from socket ($msg)", $s));
        CloseConnection($s);
      }
      return;
    } elsif ($cmd eq HELLOMSG_TETRINET or $cmd eq HELLOMSG_TETRIFAST) {
      OnTetrisstart($s, $msg);
      return;
    } elsif ( QueryMessage($s, $msg) ) {
      return;
    }

    Report('connection_error', $s, $s, RMsgDisconnect("Not received initialization message yet ($msg)", $s));
    CloseConnection($s);
    return;
  }

  if    ($cmd eq 'pline') { OnPline($s, $msg); }
  elsif ($cmd eq 'plineact') { OnPlineact($s, $msg); }
  elsif ($cmd eq 'team') { OnTeam($s, $msg); }
  elsif ($cmd eq 'startgame') { OnStartgame($s, $msg); }
  elsif ($cmd eq 'pause') { OnPause($s, $msg); }
  elsif ($cmd eq 'playerlost') { OnPlayerlost($s, $msg); }
  elsif ($cmd eq 'f') { OnF($s, $msg); }
  elsif ($cmd eq 'sb') { OnSb($s, $msg); }
  elsif ($cmd eq 'lvl') { OnLvl($s, $msg); }
  elsif ($cmd eq 'gmsg') { OnGmsg($s, $msg); }
  else {
    Report('connection_error', $s, $s, RMsgDisconnect("Unknown message from socket ($msg)", $s));
    CloseConnection($s);
  }
}

sub OnTetrisstart {
  my ($s, $msg) = @_;
  my ($cmd, @args) = split(/ /, $msg);

  # disconnects if the client has already sent a tetrisstart message
  if ($Users{$s}{client} ne '') {
    Report('connection_error', $s, $s, RMsgDisconnect("Client is already initialized ($msg)", $s));
    CloseConnection($s);
    return;
  }

  # checks client type
  if      ($cmd eq HELLOMSG_TETRINET) {
    if ( not $Config->val('Main', 'ClientTetrinet') ) {
      Send($s, 'noconnecting', [Msg('TetrinetClientNotAllowd')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Tetrinet client not allowed", $s));
      CloseConnection($s);
      return;
    }

    $Users{$s}{client} = CLIENT_TETRINET;
  } elsif ($cmd eq HELLOMSG_TETRIFAST) {
    if ( not $Config->val('Main', 'ClientTetrifast') ) {
      Send($s, 'noconnecting', [Msg('TetrifastClientNotAllowd')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Tetrifast client not allowed", $s));
      CloseConnection($s);
      return;
    }

    $Users{$s}{client} = CLIENT_TETRIFAST;
  } else {
    Report('connection_error', $s, $s, RMsgDisconnect("Unknown tetrinet client type ($cmd)", $s));
    CloseConnection($s);
    return;
  }

  # disconnects if too many arguments are passed (possibly client wanted to add some spaces to its nickname)
  if (@args > 2) {
    Send($s, 'noconnecting', [Msg('TooManyArguments')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Too many arguments ($msg)", $s));
    CloseConnection($s);
    return;
  }

  my ($nick, $version) = @args;
  $nick = '' unless defined $nick;
  $version = '' unless defined $version;

  my $sc_nick = StripColors($nick);
  my $sclc_nick = lc $sc_nick;

  # strip colors from nick if StripNameColor is on
  $nick = $sc_nick if $Config->val('Main', 'StripNameColor');

  # disconnects if nickname or color-striped nickname is empty
  if ($sc_nick eq '') {
    Send($s, 'noconnecting', [Msg('NicknameIsEmpty')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Nickname is empty ($msg)", $s));
    CloseConnection($s);
    return;
  }

  # checks nick length
  if ( length($nick) > MAXNICKLENGTH ) {
    Send($s, 'noconnecting', [Msg('TooLongNickname')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Too long nickname ($nick)", $s));
    CloseConnection($s);
    return;
  }

  # checks if the nick is reserved
  foreach my $reserved ( split(/ +/, lc $Config->val('Main', 'ReservedName')) ) {
    next unless $sclc_nick eq $reserved;
    Send($s, 'noconnecting', [Msg('ReservedName')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Attempted to use a reserved name ($nick)", $s));
    CloseConnection($s);
    return;
  }

  # disconnects if nickname or profile already exists on server
  my $profile = GetPlayerProfile($nick, MAXSTACKLEVEL);
  foreach my $player (values %Users) {
    next unless (defined $player and $player->{nick} ne '');
    my $nick2 = StripColors(lc $player->{nick});
    if ($sclc_nick eq $nick2 or $profile eq $player->{profile}) {
      Send($s, 'noconnecting', [Msg('NicknameAlreadyExists')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Nickname already exists ($nick)", $s));
      CloseConnection($s);
      return;
    }
  }

  $Users{$s}{nick} = $nick;

  # checks protocol version
  if ($version ne PROTOCOLVERSION) {
    Send($s, 'noconnecting', [Msg('VersionDifference', $version, PROTOCOLVERSION)]);
    Report('connection_error', $s, $s, RMsgDisconnect("Unknown tetrinet client version ($version)", $s));
    CloseConnection($s);
    return;
  }

  $Users{$s}{version} = $version;

  # checks ban entry
  my $ip = $Users{$s}{ip};
  my $host = $Users{$s}{host};

  my $result = CheckBan($profile->[PF_PNAME], $ip, $host);
  if (defined $result) {
    my ($mnick, $mhost) = @$result;
    Send($s, 'noconnecting', [Msg('Banned')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Banned from server (nick=$nick, ip=$ip, host=$host, mask=$mnick $mhost)", $s));
    CloseConnection($s);
    return;
  }

  # checks the number of users from the same ip address
  if ( $Config->val('Main', 'UsersFromSameIP') > 0 ) {
    my $num = 0;
    foreach my $player (values %Users) {
      next unless defined $player;
      $num++ if $player->{ip} eq $ip; # also his/her self will be counted
      last if $num > $Config->val('Main', 'UsersFromSameIP');
    }
    if ( $num > $Config->val('Main', 'UsersFromSameIP') ) {
      Send($s, 'noconnecting', [Msg('TooManyHostConnections')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Too many host connections (IP=$ip, Host=$host)", $s));
      CloseConnection($s);
      return;
    }
  }

  # let the client join a channel
  my $opench = OpenChannel();
  if (defined $opench) {
    JoinChannel($s, $opench, 1);
  } else {
    my $maxchannels = $Config->val('Main', 'MaxChannels');
    if ( $maxchannels <= 0 or @Channels < $maxchannels ) {
    # creat a new channel
      my @chs = ();
      my $default = $Config->val('ChannelDefault', 'Name');
      foreach my $ch (@Channels) {
        push(@chs, $1) if ($ch->{name} =~ /^$default(\d+)$/);
      }
      my $name;
      for (my $i=1; ; $i++) {
        if (not grep {$_ eq $i} @chs) {
          $name = $default . $i;
          last;
        }
      }

      my $ch = {InitialChannelData(), name => $name};
      NormalizeChannelConfig($ch);
      push(@Channels, $ch);
      JoinChannel($s, $ch, 1);
    } else {
      Send($s, 'noconnecting', [Msg('ServerIsFull')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Server is full", $s));
      CloseConnection($s);
      return;
    }
  }

  # if VerifyClient is on, lets begin verifying
  StartVerifyClient($s) if $Config->val('Main', 'VerifyClient');

  $Users{$s}{profile} = $profile;
  if ($Users{$s}{profile}[PF_PPASSWORD] ne '') {
    # if client is registered, lets begin certifying
    StartCertifyClient($s);
  } else {
    $Users{$s}{profile}[PF_PAUTHORITY] = $Config->val('Authority', 'User');
  }
  NormalizePlayerProfileData($Users{$s}{profile});

  Report('connection', $s, $s,
      sprintf("New Connection %s [%s %s] %s(%s) joined %s / %s",
              $Users{$s}{nick}, $Users{$s}{client}, $Users{$s}{version},
              $Users{$s}{ip}, $Users{$s}{host}, ChannelName($Users{$s}{channel}), $Users{$s}{slot}
      )
  );
}

sub OnPline {
  my ($s, $msg) = @_;
  my ($cmd, $oslot, $message) = split(/ /, $msg, 3);
  $message = '' unless defined $message;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  if ( IsCertifyingClient($s) ) {
    my $pass = StripColors($message);
    my $crypted = $Users{$s}{profile}[PF_PPASSWORD];
    if ( CheckPassword($pass, $crypted) ) {
      EndCertifyClient($s);
    } else {
      Send($s, 'pline', 0, [Msg('InvalidPassword')]);
      Report('connection_error', $s, $s, RMsgDisconnect("Invalid password for registered nick", $s));
      CloseConnection($s);
    }
    return;
  }
  return if defined $ch->{reserved}[$slot];

  AddAntiFlood($s, length($message)) or return;
  if ( substr(StripColors($message), 0, length(COMMANDPREFIX)) eq COMMANDPREFIX ) {
  # partyline command
    my $pl_msg = substr($message, index($message, COMMANDPREFIX) + length(COMMANDPREFIX));
    DoPlCmd($s, $pl_msg);
  } else {
  # chat message
    SendToChannel($ch, $slot, 'pline', $slot, [$message]);
    my $chname = ChannelName($ch);
    my $nick = $Users{$s}{nick};
    Report('chat', $s, $s, "[$chname] Chat: <$nick> $message");
  }
}

sub OnPlineact {
  my ($s, $msg) = @_;
  my ($cmd, $oslot, $action) = split(/ /, $msg, 3);
  $action = '' unless defined $action;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  return if defined $ch->{reserved}[$slot];

  AddAntiFlood($s, length($action)) or return;
  SendToChannel($ch, $slot, 'plineact', $slot, [$action]);
  my $chname = ChannelName($ch);
  Report('chat', $s, $s, "[$chname] Action: $Users{$s}{nick} $action");
}

sub OnTeam {
  my ($s, $msg) = @_;
  my ($cmd, $oslot, $team) = split(/ /, $msg, 3);
  $team = '' unless defined $team;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  $team = StripColors($team) if $Config->val('Main', 'StripNameColor');
  if ( length($team) > MAXTEAMLENGTH ) {
    Report('connection_error', $s, $s, RMsgDisconnect("Too long team name ($team)", $s));
    CloseConnection($s);
    return;
  }

  my $pn = pop @{$Users{$s}{playernum}};
  if (defined $pn and $oslot != $pn->{slot}) {
    push(@{$Users{$s}{playernum}}, $pn);
    $pn = undef;
  }

  if ( defined $pn and defined $pn->{pingbuf} ) {
    unshift(@{$Users{$s}{ping}}, TimeInterval($pn->{pingbuf}, RealTime()));
    pop @{$Users{$s}{ping}} if (@{$Users{$s}{ping}} > PINGAVE);
    Send($s, 'pline', 0, [Msg('Pong', PingLatest($s), PingAve($s))]) if $pn->{pingmsg};
  }

  # while server is checking client, processing `team' messages needs to stop here
  if ( defined $pn and IsCheckingClient($s) ) {
    $pn->{pingbuf} = undef;
    push(@{$Users{$s}{playernum}}, $pn);
    $Users{$s}{team} = $team;
    return;
  }

  if ( defined $pn and $pn->{sendplayerjoin} ) {
    SendToChannel($ch, $slot, 'playerjoin', $slot, $Users{$s}{nick});
    my $slot = $Users{$s}{slot};
    $ch->{players}[$slot] = $s;
    $ch->{reserved}[$slot] = undef;
    SendToChannel($ch, $slot, 'playerlost', $slot);
  } else {
    return if defined $ch->{reserved}[$slot];
    return if $Users{$s}{team} eq $team;
    if ($ch->{ingame} and $Users{$s}{alive}) {
      Send($s, 'pline', 0, [Msg('CannotChangeTeamWhileInGame')]);
      Send($s, 'team', $slot, $Users{$s}{team});
      return;
    }
  }

  $Users{$s}{team} = $team;
  AddAntiFlood($s, length($team)) or return;
  SendToChannel($ch, $slot, 'team', $slot, $team);
  my $chname = ChannelName($ch);
  Report('team', $s, $s, "[$chname] $Users{$s}{nick} changed team to $team");

  if ( defined $pn and $pn->{sendplayerjoin} ) {
    if ( $pn->{justconnected} ) {
      OnPlayerConnected($s);
      SendChannelInfo($s, 1);
    } else {
      SendToChannel($ch, $slot, 'pline', 0, [Msg('HasJoinedChannelIn', $Users{$s}{nick}, ChannelName($ch))]);
    }
  }
}

sub OnStartgame {
  my ($s, $msg) = @_;
  my ($cmd, $toggle, $oslot) = split(/ /, $msg);
  $toggle = '' unless defined $toggle;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  return if defined $ch->{reserved}[$slot];

  if ($toggle == 1) {
    ( Send($s, 'pline', 0, [Msg('NoPermissionToStart')]), return ) unless CheckPermission($s, $Config->val('Authority', 'Start'));
    StartGame($ch, $s);
  } elsif ($toggle == 0) {
    ( Send($s, 'pline', 0, [Msg('NoPermissionToStop')]), return ) unless CheckPermission($s, $Config->val('Authority', 'Stop'));
    EndGame($ch, $s);
  }
}

sub OnPause {
  my ($s, $msg) = @_;
  my ($cmd, $toggle, $oslot) = split(/ /, $msg);
  $toggle = '' unless defined $toggle;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  return if defined $ch->{reserved}[$slot];
  return unless $ch->{ingame};
  ( Send($s, 'pline', 0, [Msg('NoPermissionToPause')]), return ) unless CheckPermission($s, $Config->val('Authority', 'Pause'));

  if ( not $ch->{paused} and $toggle == 1 ) { # pause
    PauseGame($ch, $s);
  } elsif ( $ch->{paused} and $toggle == 0 ) { # unpause
    UnpauseGame($ch, $s);
  }
}

sub OnPlayerlost {
  my ($s, $msg) = @_;
  my ($cmd, $oslot) = split(/ /, $msg);
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  if ( IsVerifyingClient($s) ) {
    my $enum = scalar @{$Users{$s}{verified}}; # number of field changes
    if ($enum != VERIFY_FIELDCHANGES) {
      Report('connection_error', $s, $s, RMsgDisconnect("Too many/less field changes on verifying ($enum)", $s));
      CloseConnection($s);
      return;
    }

    my $interval = TimeInterval( $Users{$s}{verified}[0], $Users{$s}{verified}[$enum-1] );
    my $client = $Users{$s}{client};
    my ($lowest, $highest);
    if ( $Config->val('Main', 'VerifyStrictly') ) {
      $lowest = VERIFY_STRICT->{$client}->[2];
      $highest = VERIFY_STRICT->{$client}->[3];
    } else {
      $lowest = VERIFY_LOOSE->{$client}->[2];
      $highest = VERIFY_LOOSE->{$client}->[3];
    }

    # disconnects if the interval is not in the range
    unless ($lowest <= $interval and $interval <= $highest) {
      Report('connection_error', $s, $s, RMsgDisconnect("Too fast/slow game end on verifying ($interval)", $s));
      CloseConnection($s);
      return;
    }

    EndVerifyClient($s);
  }

  return if defined $ch->{reserved}[$slot];
  return unless $ch->{ingame};
  return unless $Users{$s}{alive};

  AddPlayerGameInfo($ch, $s);
  SendToChannel($ch, $slot, 'playerlost', $slot) if $ch->{game}{gametype} != 2;

  CheckGameEnd($ch);
}

sub OnF {
  my ($s, $msg) = @_;
  my ($cmd, $oslot, $field) = split(/ /, $msg);
  $field = '' unless defined $field;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  if ( IsVerifyingClient($s) ) {
    push(@{$Users{$s}{verified}}, RealTime());
    my $enum = scalar @{$Users{$s}{verified}}; # number of field changes
    if ( $enum >= 2 ) {
      my $interval = TimeInterval( $Users{$s}{verified}[$enum-2], $Users{$s}{verified}[$enum-1] );
      my $client = $Users{$s}{client};
      my ($lowest, $highest);
      if ( $Config->val('Main', 'VerifyStrictly') ) {
        $lowest = VERIFY_STRICT->{$client}->[0];
        $highest = VERIFY_STRICT->{$client}->[1];
      } else {
        $lowest = VERIFY_LOOSE->{$client}->[0];
        $highest = VERIFY_LOOSE->{$client}->[1];
      }
      # disconnects if the interval is not in the range
      unless ($lowest <= $interval and $interval <= $highest) {
        Report('connection_error', $s, $s, RMsgDisconnect("Too fast/slow block interval on verifying ($interval)", $s));
        CloseConnection($s);
        return;
      }
    }
  }

  return if defined $ch->{reserved}[$slot];
  return unless $ch->{ingame};

  my $old = $Users{$s}{field};
  my $new = UpdateField($old, $field);
  if (not defined $new) {
    Report('connection_error', $s, $s, RMsgDisconnect("Invalid field data ($field)", $s));
    CloseConnection($s);
    return;
  }
  $Users{$s}{field} = $new;
  SendToChannel($ch, $Users{$s}{slot}, 'f', $slot, $field);

  GameStatsOnF($s, $old, $new, $field);
}

sub OnSb {
  my ($s, $msg) = @_;
  my ($cmd, $to, $sb, $ofrom) = split(/ /, $msg);
  $to = '' unless defined $to;
  $sb = '' unless defined $sb;
  my $ch = $Users{$s}{channel};
  my $from = $Users{$s}{slot};

  return if defined $ch->{reserved}[$from];
  return unless $ch->{ingame};
  return unless $Users{$s}{alive};

  if ($sb =~ /^cs(\d+)$/) {
    my $num = $1;
    if ($num == 3) {
      Report('connection_error', $s, $s, RMsgDisconnect("Cheating - impossible add_line_to_all ($msg)", $s));
      CloseConnection($s);
      return;
    }
  } else {
    if ( IsPure($ch) ) {
      Report('connection_error', $s, $s, RMsgDisconnect("Cheating - special block used on pure ($msg)", $s));
      CloseConnection($s);
      return;
    }
  }

  SendToChannel($ch, $Users{$s}{slot}, 'sb', $to, $sb, $from) if $ch->{game}{gametype} != 2;

  GameStatsOnSb($s, $to, $sb, $from);
}

sub OnLvl {
  my ($s, $msg) = @_;
  my ($cmd, $oslot, $level) = split(/ /, $msg);
  $level = '' unless defined $level;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  return if defined $ch->{reserved}[$slot];
  return unless $ch->{ingame};
  return unless $Users{$s}{alive};

  return if $ch->{game}{gametype} == 2;
  SendToChannel($ch, 0, 'lvl', $slot, $level);
}

sub OnGmsg {
  my ($s, $msg) = @_;
  my ($cmd, $nick, $message) = split(/ /, $msg, 3);
  $message = '' unless defined $message;
  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  return if defined $ch->{reserved}[$slot];
  return unless StripColors($nick) eq ("<" . StripColors($Users{$s}{nick}) . ">");

  if ( $Config->val('Main', 'StripGmsgColor') ) {
    $nick = StripColors($nick);
    $message = StripColors($message);
  }

  if ( $Config->val('Main', 'InterceptGmsgPing') and $message eq GMSGPING ) {
    Send($s, 'gmsg', [GMSGPONG]);
  } elsif ( $Config->val('Main', 'InterceptGmsgPause') and $message eq GMSGPAUSE ) {
    ( Send($s, 'gmsg', [Msg('NoPermissionToPauseGmsg')]), return ) unless CheckPermission($s, $Config->val('Authority', 'Pause'));
    my $toggle = ($ch->{paused} ? 0 : 1);
    OnPause($s, "pause $toggle $slot");
  } else {
    AddAntiFlood($s, length($message)) or return;
    SendToChannel($ch, 0, 'gmsg', $nick, [$message]);
    my $chname = ChannelName($ch);
    Report('chat', $s, $s, "[$chname] Game message: $nick $message");
  }
}

sub SendPlayernum {
  my ($s, $slot) = @_;

  Send($s, Playernum($s), $slot);

  unshift(@{$Users{$s}{playernum}}, {
    pingbuf => RealTime(),
    pingmsg => undef,
    slot => $slot,
    justconnected => undef,
    sendplayerjoin => undef,
  });
}

sub OnPlayerConnected {
  my ($s) = @_;

  $Users{$s}{profile}[PF_PLOGINS]++;
  $Users{$s}{profile}[PF_PLASTLOGIN] = Time();

  $Daily{logins}++;
  SetDailyNowplayers();
}

# =================================================================
#     Query protocol functions
# =================================================================

sub QueryMessage {
  my ($s, $msg) = @_;
  return unless defined $Users{$s};

  my %cmds = (
    listchan => \&OnQueryListchan,
    listuser => \&OnQueryListuser,
    playerquery => \&OnQueryPlayerquery,
    version => \&OnQueryVersion,
  );

  my ($cmd, $args) = split(/ /, $msg, 2);
  if ( grep {$_ eq $cmd} (keys %cmds) ) {
    my $connected = 1 if $Users{$s}{client} eq '';
    $Users{$s}{client} = CLIENT_QUERY;

    if ( not $Config->val('Main', 'ClientQuery') ) {
      Send($s, 'noconnecting', [Msg('QueryAccessNotAllowd')]);
      Report('query', $s, $s, RMsgDisconnect("Query access not allowed", $s));
      CloseConnection($s);
      return 1;
    }

    my $ip = $Users{$s}{ip};
    Report('query', $s, $s, "New Connection $ip [query]") if $connected;
    Report('query', $s, $s, "Query: $msg");

    my $sub = $cmds{$cmd};
    &$sub($s, $msg) if defined $sub;
    return 1;
  }

  return undef;
}

sub OnQueryPlayerquery {
  my ($s, $msg) = @_;

  my $opench = OpenChannel();
  if (defined $opench) {
    my $players = NumberPlayers($opench);
    Send($s, ["Number of players logged in: $players"]);
  } else {
    my $maxchannels = $Config->val('Main', 'MaxChannels');
    if ( $maxchannels <= 0 or @Channels < $maxchannels ) {
      Send($s, ["Number of players logged in: 0"]);
    } else {
      Send($s, 'noconnecting', [Msg('ServerIsFull')]);
    }
  }
}

sub OnQueryVersion {
  my ($s, $msg) = @_;

  Send($s, ["$PROGRAM_NAME"]);
  Send($s, ["+OK"]);
}

sub OnQueryListchan {
  my ($s, $msg) = @_;

  foreach my $ch (@Channels) {
    my $name = $ch->{name};
    my $topic = $ch->{topic};
    my $players = NumberPlayers($ch);
    my $max = $ch->{maxplayers};
    my $priority = $ch->{priority};
    my $status = 1;
    if ( $ch->{ingame} ) { $status = ($ch->{paused} ? 3 : 2); }
    Send($s, [qq{"$name" "$topic" $players $max $priority $status}]);
  }
  Send($s, ["+OK"]);
}

sub OnQueryListuser {
  my ($s, $msg) = @_;

  foreach my $player (values %Users) {
    next unless (defined $player and $player->{nick} ne '');
    my $user = $player->{socket};

    my $nick = $player->{nick};
    my $team = $player->{team};
    my $version = $player->{version};
    my $slot = $player->{slot};
    my $ch = $player->{channel};
    my $state = 0;
    if ( $ch->{ingame} ) { $state = ($player->{alive} ? 1 : 2); }
    my $auth = AuthorityLevel($user);
    my $chname = $ch->{name};
    Send($s, [qq{"$nick" "$team" "$version" $slot $state $auth "$chname"}]);
  }
  Send($s, ["+OK"]);
}

# =================================================================
#     Lookup protocol/Host name functions
# =================================================================

sub LookupMessage {
  my ($s, $msg) = @_;
  Report('lookup', $s, $s, "Lookup: $msg");

  my ($ip, $host) = split(/\s+/, $msg);
  return unless defined $ip;
  $host = '' unless defined $host;

  my $expire = PTime() + (LOOKUPEXPIRE * 60);
  $Misc{ip2host}{$ip} = [$host, $expire];
}

sub LookupHost {
  my ($s) = @_;

  my $ip = $Users{$s}{ip};
  if (defined $Misc{ip2host}{$ip}) {
    my $host = $Misc{ip2host}{$ip}[0];
    SetHost($s, $host);
    return;
  }

  my $pid = (NOFORK ? undef : fork());
  if (defined $pid) {
    if ($pid) { # parent process
      my $timeout = PTime() + LOOKUPTIMEOUT;
      $Misc{waitinglookup}{$s} = [$s, $ip, $timeout];
    } else { # child process
      my $addr = inet_aton($ip);
      my $host = gethostbyaddr($addr, AF_INET);
      $host = '' unless defined $host;

      my $socket = IO::Socket::INET->new(
        PeerAddr => LOCALHOST,
        PeerPort => LOOKUPPORT,
        Proto => 'tcp',
      ) or exit 1;
      binmode $socket;

      my $term = TERMINATOR;
      print $socket "$ip $host$term";
      $socket->close();

      exit 0;
    }
  } else { # fork() failed
    Report('debug', undef, undef, "DEBUG: fork() failed") if not NOFORK;
    my $addr = inet_aton($ip);
    my $host = gethostbyaddr($addr, AF_INET);
    SetHost($s, $host);

    my $expire = PTime() + (LOOKUPEXPIRE * 60);
    $Misc{ip2host}{$ip} = [$host, $expire];
  }
}

sub CheckWaitingLookup {
  my $time = PTime();
  foreach ( values %{$Misc{waitinglookup}} ) {
    next unless defined $_;
    my ($s, $ip, $timeout) = @$_;
    if (defined $Misc{ip2host}{$ip}) {
      my $host = $Misc{ip2host}{$ip}[0];
      SetHost($s, $host);
      delete $Misc{waitinglookup}{$s};
    } elsif (LOOKUPTIMEOUT) {
      next unless $timeout <= $time;
      SetHost($s, '');
      delete $Misc{waitinglookup}{$s};

      my $expire = $time + (LOOKUPEXPIRE * 60);
      $Misc{ip2host}{$ip} = ['', $expire];
    }
  }
}

sub CheckLookupExpire {
  return unless LOOKUPEXPIRE > 0;

  my $time = PTime();
  foreach my $ip (keys %{$Misc{ip2host}}) {
    next unless defined $Misc{ip2host}{$ip};
    my ($host, $expire) = @{$Misc{ip2host}{$ip}};
    next unless $expire <= $time;
    delete $Misc{ip2host}{$ip};
  }
}

sub SetHost {
  my ($s, $host) = @_;

  $Users{$s}{host} = $host;
  $Misc{readable}->add($s);
}

# =================================================================
#     Partyline command functions
# =================================================================

sub PlCommands {
  my %cmds = (
    alias => \&OnPlAlias,
    auth => \&OnPlAuth,
    ban => \&OnPlBan,
    board => \&OnPlBoard,
    broadcast => \&OnPlBroadcast,
    dstats => \&OnPlDstats,
    file => \&OnPlFile,
    find => \&OnPlFind,
    grant => \&OnPlGrant,
    gstats => \&OnPlGstats,
    help => \&OnPlHelp,
    info => \&OnPlInfo,
    join => \&OnPlJoin,
    kick => \&OnPlKick,
    kill => \&OnPlKill,
    lang => \&OnPlLang,
    list => \&OnPlList,
    lmsg => \&OnPlLmsg,
    load => \&OnPlLoad,
    motd => \&OnPlMotd,
    move => \&OnPlMove,
    msg => \&OnPlMsg,
    msgto => \&OnPlMsgto,
    news => \&OnPlNews,
    passwd => \&OnPlPasswd,
    pause => \&OnPlPause,
    ping => \&OnPlPing,
    quit => \&OnPlQuit,
    reg => \&OnPlReg,
    reset => \&OnPlReset,
    save => \&OnPlSave,
    score => \&OnPlScore,
    set => \&OnPlSet,
    shutdown => \&OnPlShutdown,
    start => \&OnPlStart,
    stop => \&OnPlStop,
    teleport => \&OnPlTeleport,
    time => \&OnPlTime,
    topic => \&OnPlTopic,
    unban => \&OnPlUnban,
    unreg => \&OnPlUnreg,
    version => \&OnPlVersion,
    who => \&OnPlWho,
    winlist => \&OnPlWinlist,
  );

  my %ret = ();
  $ret{lc $_} = $cmds{$_} foreach (keys %cmds);
  return \%ret;
}

sub DoPlCmd {
  my ($s, $msg) = @_;

  my ($cmd, $args) = split(/ +/, $msg, 2);
  $cmd = '' unless defined $cmd; $args = '' unless defined $args;
  my $page = ($cmd =~ s/(\d+)$// ? $1 : '');

  my ($rcmd, $ralias, $rargs) = CommandMatch($cmd);
  if ($rcmd eq '') {
    Send($s, 'pline', 0, [Msg('InvalidCommand')]);
    return undef;
  }
  return undef unless CheckCommandPermission($s, $rcmd, undef);

  $msg = ($ralias or $rcmd) . ($rargs ne '' ? " $rargs" : '') . ($args ne '' ? " $args" : '');

  my $sub = $Misc{commands}{$rcmd};
  &$sub($s, $msg, $page) if defined $sub;
}

# returns (command, alias args, alias);
sub CommandMatch {
  my ($cmd) = @_;

  return ('', '', '') if (not defined $cmd or $cmd eq '');
  $cmd = lc $cmd;

  my $commands = $Misc{command_names};

  my $aliases = $Misc{command_aliases};
  foreach my $alias (keys %$aliases) {
    next unless $cmd eq $alias;
    my ($acmd, $aargs) = split(/ +/, $aliases->{$alias}, 2);
    $acmd = '' unless defined $acmd; $aargs = '' unless defined $aargs;
    if ( grep {$_ eq $acmd} @$commands ) {
      return ($acmd, $cmd, $aargs);
    } else {
      Report('error', undef, undef, "ERROR: Wrong command alias ($cmd=$acmd)");
      return ('', $cmd, '');
    }
  }

  return ($cmd, '', '') if ( grep {$_ eq $cmd} @$commands );

  my @names = @$commands;
  for (my $i=0; $i<length($cmd); $i++) {
    for (my $j=0; $j<@names; $j++) {
      next if ( substr($cmd, $i, 1) eq substr($names[$j], $i, 1) );
      splice(@names, $j, 1);
      $j--;
    }
    last if @names == 1;
  }
  return ((@names == 1 ? $names[0] : ''), '', '');
}

sub SendCommandFormat {
  my ($s, @args) = @_; # $cmd, $item) = @_;

  my $cmd = lc $args[0];

  foreach (@args) {
    my $name = ucfirst lc $_;
    if ( $name ne '' and Msg($s, "Format$name") ne '' ) {
      Send($s, 'pline', 0, [Msg('Format'), Msg("Format$name", Msg('ColorCommandUsable'), COMMANDPREFIX . $cmd)]);
      return;
    }
  }

  Report('error', undef, undef, "ERROR: No format message for command $cmd");
}

sub OnPlAlias {
  my ($s, $msg, $page) = @_;
  my ($cmd, $real, $alias) = split(/ +/, $msg);

  $real = StripColors($real);
  $alias = StripColors($alias);
  $alias = StripColors($Users{$s}{nick}) if $alias eq '';

  if ($real eq '-') {
    my $profile = GetPlayerProfile($alias, 0);
    $profile->[PF_PALIAS] = '';
    Send($s, 'pline', 0, [Msg('UnregisteredAlias', $alias)]);
    Report('profile', $s, $s, "$Users{$s}{nick} unregistered real nickname for $alias");
  } elsif ($real ne '') {
    my $profile = GetPlayerProfile($alias, 0);
    $profile->[PF_PALIAS] = $real;
    Send($s, 'pline', 0, [Msg('RegisteredAlias', $real, $alias)]);
    Report('profile', $s, $s, "$Users{$s}{nick} registered alias $alias for $real");
  } else {
    SendCommandFormat($s, $cmd, 'alias');
  }
}

sub OnPlAuth {
  my ($s, $msg, $page) = @_;
  my ($cmd, $level, $pass) = split(/ +/, $msg);
  $pass = '' unless defined $pass;

  my $nick = $Users{$s}{nick};
  my $auth = $Users{$s}{profile}[PF_PAUTHORITY];

  $level = AuthorityLevel_ston($level);

  if ($level eq '') {
    Send($s, 'pline', 0, [Msg('Authority', $nick, $auth)]);
  } elsif ($level !~ /\D/ and 0 <= $level) {
    $pass = StripColors($pass);
    if ($auth < $level or $pass ne '') {
      my $crypted = $Misc{passwords}[$level];
      if ( not CheckPassword($pass, $crypted) ) {
        Send($s, 'pline', 0, [Msg('InvalidPassword')]);
        Report('auth', $s, $s, "$nick specified invalid password for $level");
        return;
      }
    }
    $auth = $level;
    $Users{$s}{profile}[PF_PAUTHORITY] = $level;
    Send($s, 'pline', 0, [Msg('Authority', $nick, $level)]);
    Report('auth', $s, $s, "$nick gained authority $level");
  } else {
    SendCommandFormat($s, $cmd, 'auth');
  }
}

sub OnPlBan {
  my ($s, $msg, $page) = @_;
  my ($cmd, @args) = split(/ +/, $msg);

  if (@args == 0) {
    Send($s, 'pline', 0, [Msg('ListingBan')]);
    SendBanList($s);
  } else {
    my $opts = '-';
    my ($nick, $host, $expire);
    if ($args[0] =~ /^-/) {
      ($opts, $nick, $host, $expire) = @args;
    } else {
      ($nick, $host, $expire) = @args;
    }
    ( SendCommandFormat($s, $cmd, 'ban'), return ) unless (defined $nick and defined $host);

    $expire = stoiBanExpire($expire);
    my $result = AddBanMask($opts, $nick, $host, $expire, '');

    my $mask = "$opts $nick $host";
    if ($result) {
      Send($s, 'pline', 0, [Msg('BannedUser', $mask)]);
      Report('ban', $s, $s, "$Users{$s}{nick} added ban mask: $mask");
    } else {
      Send($s, 'pline', 0, [Msg('FailedToAddBanMask', $mask)]);
    }
  }
}

sub OnPlBoard {
  my ($s, $msg, $page) = @_;
  my ($cmd, $arg, $rest) = split(/ +/, $msg, 3);
  $arg = '' unless defined $arg;
  $rest = '' unless defined $rest;

  my $write = undef;
  my $delete = undef;
  if ($arg =~ /^-/) {
    $arg = lc $arg;
    foreach my $opt ( split(//, $arg) ) {
      if ($opt eq '-') {
        # any `-' will be ignored
      } elsif ($opt eq 'w') {
        $write = 1;
      } elsif ($opt eq 'd') {
        $delete = 1;
      } else {
        Send($s, 'pline', 0, [Msg('InvalidParameters')]);
        return;
      }
    }
  }

  my $to = 'BOARD';
  if ($write) {
    ( Send($s, 'pline', 0, [Msg('NoPermissionToCommand')]), return ) unless CheckPermission($s, $Config->val('Command', 'BoardWrite'));
    my $message = StripColors($rest);
    $message =~ s/^\s+//; $message =~ s/\s+$//;
    ( SendCommandFormat($s, $cmd, 'board'), return ) if $message eq '';

    my $from = StripColors($Users{$s}{nick});
    my $time = Time();
    AddLmsg($to, $from, $time, $message);
    Send($s, 'pline', 0, [Msg('MessageWrittenToMessageBoard')]);
    my $no = scalar @{$Lmsg{$to}};
    Report('board', $s, $s, "$from wrote a message to the Message Board: $no. <$from> $message");
  } elsif ($delete) {
    ( Send($s, 'pline', 0, [Msg('NoPermissionToCommand')]), return ) unless CheckPermission($s, $Config->val('Command', 'BoardDelete'));
    ( Send($s, 'pline', 0, [Msg('ThereAreNoMessages')]), return ) if (not defined $Lmsg{$to} or @{$Lmsg{$to}} == 0);
    my $no = ToInt($rest, 0, undef) - 1;
    ( SendCommandFormat($s, $cmd, 'board'), return ) unless ($no >= 0 and defined $Lmsg{$to}[$no]);

    my @deleted = splice(@{$Lmsg{$to}}, $no, 1);

    Send($s, 'pline', 0, [Msg('MessageDeletedFromMessageBoard')]);
    my ($dfrom, $dtime, $dmsg) = @{$deleted[0]};
    Report('board', $s, $s, "$Users{$s}{nick} deleted a message from the Message Board: $no. <$dfrom> $dmsg");
  } else {
    ( Send($s, 'pline', 0, [Msg('ThereAreNoMessages')]), return ) if (not defined $Lmsg{$to} or @{$Lmsg{$to}} == 0);

    $page = ToInt($page, 1, undef);
    my $numnames = ToInt($Config->val('Command', 'PageBoard'), 1, 100);
    my $start = ($page - 1) * $numnames;
    my $last = $page * $numnames;

    my $len = scalar(@{$Lmsg{$to}}) - 1;
    my $rstart = $len - $start;
    my $rlast = $len - $last;
    Send($s, 'pline', 0, [Msg('ListingBoard', $page)]);
    for (my $i=$rstart; $i>$rlast; $i--) {
      last unless ($i >= 0 and defined $Lmsg{$to}[$i]);
      my $no = $i + 1;
      my ($from, $time, $msg) = @{$Lmsg{$to}[$i]};
      my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime($time);
      my $date = "$mon/$mday $hour:$min";
      Send($s, 'pline', 0, [Msg('ListBoard', $no, $from, $date, $msg)]);
    }
    my $nextpage = ($rlast >= 0 and defined $Lmsg{$to}[$rlast]);

    if ($nextpage) {
      my $next = COMMANDPREFIX . $cmd . ($page + 1);
      Send($s, 'pline', 0, [Msg('ListTooLong', $next)]);
    }
  }
}

sub OnPlBroadcast {
  my ($s, $msg, $page) = @_;
  my ($cmd, $message) = split(/ +/, $msg, 2);
  $message = '' unless defined $message;

  if ($message ne '') {
    my $nick = $Users{$s}{nick};
    SendToAll('pline', 0, [Msg('Broadcast', $nick, $message)]);
    Report('chat', undef, $s, "Broadcast: <$nick> $message");
  } else {
    SendCommandFormat($s, $cmd, 'broadcast');
  }
}

sub OnPlDstats {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  my @dstats = (
    $Daily{games}, $Daily{highestplayers},
    $Daily{logins}, $Daily{nowplayers},
  );

  Send($s, 'pline', 0, [Msg('Dstats')]);
  for (my $i=1; ; $i++) {
    last if Msg($s, "Dstats$i") eq '';
    Send($s, 'pline', 0, [Msg("Dstats$i", @dstats)]);
  }
}

sub OnPlFile {
  my ($s, $msg, $page) = @_;
  my ($cmd, $name, $target) = split(/ +/, $msg);
  $name = '' unless defined $name;
  $target = '' unless defined $target;

  if ($name ne '') {
    $name = lc $name;
    unless ( $Config->val('FilePath', $name) ne '') {
      SendFileList($s);
      return;
    }
    if ($target ne '') {
      my %count;
      my @targets = grep {1 <= $_ and $_ <= MAXPLAYERS and !$count{$_}++} split(//, $target);
      if (@targets) {
        my $ch = $Users{$s}{channel};
        foreach my $slot (@targets) {
          next unless defined $ch->{players}[$slot];
          my $user = $ch->{players}[$slot];
          Send($user, 'pline', 0, [Msg('FileFrom', $Users{$s}{nick})]);
          SendFromFile($user, $name);
          Send($s, 'pline', 0, [Msg('SentFile', $Users{$user}{nick})]);
        }
      } else {
        SendCommandFormat($s, $cmd, 'file');
        return;
      }
    } else {
      SendFromFile($s, $name);
    }
  } else {
    SendFileList($s);
  }
}

sub SendFileList {
  my ($s) = @_;

  Send($s, 'pline', 0, [Msg('ListingFileList')]);

  my $buf = '';
  foreach my $name ( $Config->Parameters('FilePath') ) {
    next if $name eq '';
    $name .= ' ' x (8 - (length($name) % 8));
    $name .= ' ' x 8 if $name !~ / $/;
    $buf .= $name;
    if (length $buf >= 8*4) {
      Send($s, 'pline', 0, [$buf]);
      $buf = '';
    }
  }
  Send($s, 'pline', 0, [$buf]) if $buf ne '';
}

sub OnPlFind {
  my ($s, $msg, $page) = @_;
  my ($cmd, @args) = split(/ +/, $msg);

  my $keyword = '';
  foreach my $arg (@args) {
    next if (not defined $arg or $arg eq '');
    $arg = lc $arg;
    $keyword = $arg;
  }

  if ($keyword ne '') {
    my @matches = ();
    foreach my $player (values %Users) {
      next unless (defined $player and $player->{nick} ne '');
      my $nick = lc $player->{nick};
      push(@matches, $player) if index($nick, $keyword) > -1;
    }
    if (@matches != 0) {
      foreach my $player (@matches) {
        my $nick = $player->{nick};
        my $chname = ChannelName($player->{channel});
        Send($s, 'pline', 0, [Msg('ListFind', $nick, $chname)]);
      }
    } else {
      Send($s, 'pline', 0, [Msg('NoMatchForQuery')]);
    }
  } else {
    SendCommandFormat($s, $cmd, 'find');
  }
}

sub OnPlGrant {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target, $level) = split(/ +/, $msg);

  my $user = TargetNick($target);
  if (defined $user) {
    my $nick = $Users{$user}{nick};

    $level = AuthorityLevel_ston($level);

    if ($level eq '') {
      my $auth = $Users{$user}{profile}[PF_PAUTHORITY];
      Send($s, 'pline', 0, [Msg('Authority', $nick, $auth)]);
    } elsif ($level !~ /\D/ and 0 <= $level) {
      if ($level > $Users{$s}{profile}[PF_PAUTHORITY]) {
        Send($s, 'pline', 0, [Msg('CannotGiveHigherAuthority')]);
        return;
      } elsif ($Users{$user}{profile}[PF_PAUTHORITY] > $Users{$s}{profile}[PF_PAUTHORITY]) {
        Send($s, 'pline', 0, [Msg('CannotDeprive')]);
        return;
      }
      $Users{$user}{profile}[PF_PAUTHORITY] = $level;
      Send($s, 'pline', 0, [Msg('Authority', $nick, $level)]);
      Send($user, 'pline', 0, [Msg('Granted', $Users{$s}{nick})]);
      Send($user, 'pline', 0, [Msg('Authority', $nick, $level)]);
      Report('auth', [$s, $user], $s, "$Users{$s}{nick} granted $nick authority level $level");
    } else {
      SendCommandFormat($s, $cmd, 'grant');
    }
  } else {
    SendCommandFormat($s, $cmd, 'grant');
  }
}

sub OnPlGstats {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  my $ch = $Users{$s}{channel};
  ( Send($s, 'pline', 0, [Msg('CannotUseCommandNow')]), return ) if not defined $ch->{game}{timestart};

  if ($ch->{ingame}) {
    my @players = @{$ch->{game}{players}};
    for (my $i=1; $i<=MAXPLAYERS; $i++) {
      my $user = $ch->{players}[$i] or next;
      next unless $Users{$user}{alive};

      my %info = (
        nick => $Users{$user}{nick},
        csadded => $Users{$user}{gs}{csadded},
        lifetime => GameTime($ch),
        lines => $Users{$user}{gs}{lines},
        pieces => $Users{$user}{gs}{pieces},
        specials => $Users{$user}{gs}{specials},
        tetris => $Users{$user}{gs}{tetris},
        ud => '-', # $Users{$user}{gs}{ud},
      );
      unshift(@players, \%info);
    }

    AnnounceStats($ch, \@players, $s);
  } else {
    AnnounceStats($ch, $ch->{game}{players}, $s);
  }
}

sub OnPlHelp {
  my ($s, $msg, $page) = @_;
  my ($cmd, $arg) = split(/ +/, $msg);

  $arg = '-b' if (not defined $arg or $arg eq '');
  if ($arg =~ /^-/) {
    my $type = '';
    $arg = lc $arg;
    foreach my $opt ( split(//, $arg) ) {
      if ($opt eq '-') {
        # any `-' will be ignored
      } elsif ($opt eq 'a') {
        $type = 'all';
      } elsif ($opt eq 'b') {
        $type = 'basic';
      } elsif ($opt eq 'o') {
        $type = 'op';
      } elsif ($opt eq 'l') {
        $type = 'alias';
      } else {
        Send($s, 'pline', 0, [Msg('InvalidParameters')]);
        return;
      }
    }
    if ($type eq '') {
      SendCommandFormat($s, $cmd, 'help');
      return;
    }

    SendHelpList($s, $type, $page, $cmd, $arg);
  } else {
    my ($rcmd, $ralias, $rargs) = CommandMatch($arg);
    if ($rcmd eq '') {
      SendCommandFormat($s, $cmd, 'help');
      return;
    }

    # send format
    my $command = lc ($ralias eq '' ? $rcmd : $ralias);
    my $color = CheckCommandPermission($s, $rcmd, 1);
    foreach ($ralias, $rcmd) {
      my $name = ucfirst lc $_;
      if ( $name ne '' and Msg($s, "Format$name") ne '' ) {
        Send($s, 'pline', 0, [Msg("Format$name", $color, COMMANDPREFIX . $command)]);
        last;
      }
    }

    # send explain
    foreach ($ralias, $rcmd) {
      my $name = ucfirst lc $_;
      if ( $name ne '' and Msg($s, "Explain$name") ne '' ) {
        Send($s, 'pline', 0, [Msg("Explain$name")]);
        for (my $i=2; ; $i++) {
          last if Msg($s, "Explain$name$i") eq '';
          Send($s, 'pline', 0, [Msg("Explain$name$i")]);
        }
        last;
      }
    }
  }
}

sub SendHelpList {
  my ($s, $type, $page, $cmd, $arg) = @_;

  my @commands = ();

  if ($type eq 'alias') {
    my $aliases = $Misc{command_aliases};
    foreach my $alias (keys %$aliases) {
      my ($acmd, $aargs) = split(/ +/, $aliases->{$alias}, 2);
      push(@commands, [$acmd, $alias]) if (defined $acmd and $acmd ne '');
    }
    @commands = sort @commands;
  } else {
    my $authmod = $Config->val('Authority', 'Moderator');
    foreach ( @{$Misc{command_names}} ) {
      my $name = ucfirst lc $_;
      my $cmdperm = $Config->val('Command', $name); # command permission

      my $push = undef;
      if ($type eq 'all') {
        $push = 1 if ($cmdperm >= 0);
      } elsif ($type eq 'op') {
        $push = 1 if ($cmdperm >= 0 and $cmdperm > $authmod);
      } else {
        $push = 1 if ($cmdperm >= 0 and $cmdperm <= $authmod);
      }
      push(@commands, [$name, '']) if $push;
    }
  }

  $page = ToInt($page, 1, undef);
  my $numnames = ToInt($Config->val('Command', 'PageHelp'), 1, 100);
  my $start = ($page - 1) * $numnames;
  my $last = $page * $numnames;

  if ($type eq 'alias') {
    Send($s, 'pline', 0, [Msg('ListingHelpAlias', $PROGRAM_NAME)]);
  } elsif ($type eq 'all') {
    Send($s, 'pline', 0, [Msg('ListingHelpAll', $PROGRAM_NAME)]);
  } elsif ($type eq 'op') {
    Send($s, 'pline', 0, [Msg('ListingHelpAdmin', $PROGRAM_NAME)]);
  } else {
    Send($s, 'pline', 0, [Msg('ListingHelpBasic', $PROGRAM_NAME)]);
  }

  for (my $i=$start; $i<$last; $i++) {
    last unless defined $commands[$i];
    my ($cmdname, $alias) = @{$commands[$i]};

    # send format
    my $command = lc ($alias eq '' ? $cmdname : $alias);
    my $color = CheckCommandPermission($s, $cmdname, 1);
    foreach ($alias, $cmdname) {
      my $name = ucfirst lc $_;
      if ( $name ne '' and Msg($s, "Format$name") ne '' ) {
        Send($s, 'pline', 0, [Msg("Format$name", $color, COMMANDPREFIX . $command)]);
        last;
      }
    }

    next unless $Config->val('Command', 'HelpExplanation');

    # send explain
    foreach ($alias, $cmdname) {
      my $name = ucfirst lc $_;
      if ( $name ne '' and Msg($s, "Explain$name") ne '' ) {
        Send($s, 'pline', 0, [' ' x 4, Msg("Explain$name")]);
        last;
      }
    }
  }
  my $nextpage = (defined $commands[$last]);

  if ($nextpage) {
    $arg = '' if ( $cmd ne 'help' or ($cmd eq 'help' and $arg eq '-b') );
    my $next = COMMANDPREFIX . $cmd . ($page + 1) . ($arg ne '' ? " $arg" : '');
    Send($s, 'pline', 0, [Msg('ListTooLong', $next)]);
  }
}

sub OnPlInfo {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);

  $target = $Users{$s}{nick} if StripColors($target) eq '';
  $page = ToInt($page, 1, 2);

  if ($page == 1) {
    Send($s, 'pline', 0, [Msg('InfoA')]);
    my $user = TargetNick($target);
    if (defined $user) {
      my @info = (
        $Users{$user}{nick}, $Users{$user}{team}, # 0, 1
        $Users{$user}{channel}{name}, $Users{$user}{slot}, # 2, 3
        $Users{$user}{ip}, $Users{$user}{host}, # 4, 5
        $Users{$user}{client}, # 6
        ( PTime() - $Users{$user}{idletime} ), # 7 - idle time
        PingLatest($user), PingAve($user), # 8, 9
      );
      if ( not CheckPermission($s, $Config->val('Command', 'DisplayIP')) ) {
        $info[4] = Msg('NA'); $info[5] = Msg('NA');
      }
      for (my $i=1; ; $i++) {
        last if Msg($s, "InfoA$i") eq '';
        Send($s, 'pline', 0, [Msg("InfoA$i", @info)]);
      }
    } else {
      Send($s, 'pline', 0, [Msg('PlayerNotOnline', $target)]);
    }
    my $next = COMMANDPREFIX . $cmd . ($page + 1);
    Send($s, 'pline', 0, [Msg('InfoMore', $next)]);
  } elsif ($page == 2) {
    Send($s, 'pline', 0, [Msg('InfoB')]);
    if ( DefinedPlayerProfile($target) ) {
      my $profile = GetPlayerProfile($target, MAXSTACKLEVEL);
      my @info = @$profile;
      $info[PF_PPASSWORD] = Msg('InfoBRegistered') if $info[PF_PPASSWORD] ne '';
      $info[PF_PLASTLOGIN] = ($info[PF_PLASTLOGIN] == 0 ? Msg('NA') : LocalTime( $info[PF_PLASTLOGIN] ));
      for (my $i=1; ; $i++) {
        last if Msg($s, "InfoB$i") eq '';
        Send($s, 'pline', 0, [Msg("InfoB$i", @info)]);
      }
    } else {
      Send($s, 'pline', 0, [Msg('NoEntryFound', $target)]);
    }
  } else {
    SendCommandFormat($s, $cmd, 'info');
  }
}

sub OnPlJoin {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);

  my ($ch, $chname) = TargetChannel($target);
  if (defined $ch) { # existing channel
    if ( not defined OpenSlot($ch) ) {
      Send($s, 'pline', 0, [Msg('ChannelIsFull')]);
      return;
    }
    Send($s, 'pline', 0, [Msg('JoinedChannel', ChannelName($ch))]);
  } else { # not existing channel
    if ($chname ne '') {
      my $maxchannels = $Config->val('Main', 'MaxChannels');
      if ( not $Config->val('Main', 'UserMadeChannel') ) {
        Send($s, 'pline', 0, [Msg('CannotCreateNewChannel')]);
        return;
      } elsif ( $maxchannels <= 0 or @Channels < $maxchannels ) {
        # creat a new channel
        $ch = {InitialChannelData(), name => $chname};
        NormalizeChannelConfig($ch);
        push(@Channels, $ch);
        Send($s, 'pline', 0, [Msg('CreatedChannel', ChannelName($ch))]);
      } else {
        Send($s, 'pline', 0, [Msg('CannotCreateAnyMoreChannels')]);
        return;
      }
    } else {
      SendCommandFormat($s, $cmd, 'join');
      return;
    }
  }

  my $prevch = $Users{$s}{channel};
  my $toname = ChannelName($ch);
  my $fromname = ChannelName($prevch);
  my $slot = OpenSlot($ch);
  Report('join', $s, $s, "$Users{$s}{nick} joined channel $toname / $slot from $fromname");

  JoinChannel($s, $ch, 0);
  GarbageChannel($prevch);
}

sub OnPlKick {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);
  $target = '' unless defined $target;

  my %count;
  my @targets = grep {1 <= $_ and $_ <= MAXPLAYERS and !$count{$_}++} split(//, $target);

  my $ch = $Users{$s}{channel};
  my $nick = $Users{$s}{nick};
  if (@targets) {
    foreach my $slot (@targets) {
      next unless defined $ch->{players}[$slot];
      my $user = $ch->{players}[$slot];

      if ( $Config->val('Command', 'NoKickTime') > 0 ) {
        my $kicktime = $Users{$user}{timeout} + $Config->val('Command', 'NoKickTime');
        my $time = PTime();
        if ($s ne $user and $kicktime > $time) {
          Send($s, 'pline', 0, [Msg('CannotKickHimHerInNSeconds', $kicktime - $time)]);
          next;
        }
      }

      SendToChannel($ch, 0, 'pline', 0, [Msg('Kicked', $nick, $Users{$user}{nick})]);
      SendToChannel($ch, 0, 'kick', $slot);
      Report('connection_error', [$user, $s], $user, RMsgDisconnect("Kicked by $nick", $user));
      CloseConnection($user);
    }
  } else {
    SendCommandFormat($s, $cmd, 'kick');
  }
}

sub OnPlKill {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target, $expire) = split(/ +/, $msg);

  my $user = TargetNick($target);
  if (defined $user) {
    my $killer = $Users{$s}{nick};
    my $killed = $Users{$user}{nick};

    $expire = stoiBanExpire($expire);
    if ($expire) {
      my $opts = '-';
      my $nick = '*';
      my $ip = $Users{$user}{ip};
      my $host = $Users{$user}{host};
      my $time_str = LocalTime();
      my $result = AddBanMask($opts, $nick, $ip, $expire, "# $time_str - $killed $ip($host)");
      my $mask = "$opts $nick $ip";
      if ($result) {
        Send($s, 'pline', 0, [Msg('BannedUser', $mask)]);
        Report('ban', $s, $s, "$killer added ban mask: $mask");
      } else {
        Send($s, 'pline', 0, [Msg('FailedToAddBanMask', $mask)]);
      }
    }

    Send($s, 'pline', 0, [Msg('Kicked', $killer, $killed)]);
    Report('connection_error', [$user, $s], $user, RMsgDisconnect("Killed by $killer", $user));
    CloseConnection($user);
  } else {
    SendCommandFormat($s, $cmd, 'kill');
  }
}

sub OnPlLang {
  my ($s, $msg, $page) = @_;
  my ($cmd, $type) = split(/ +/, $msg);
  $type = '' unless defined $type;

  if ($type ne '') {
    $type = lc $type;
    if ($type eq 'default') {
      $Users{$s}{profile}[PF_PLOCALE] = '';
      Send($s, 'pline', 0, [Msg('Locale', $type)]);
    } else {
      if (defined $Msg{$type}) {
        $Users{$s}{profile}[PF_PLOCALE] = $type;
        Send($s, 'pline', 0, [Msg('Locale', $type)]);
      } else {
        SendCommandFormat($s, $cmd, 'lang');
      }
    }
  } else {
    my $locale = $Users{$s}{profile}[PF_PLOCALE];
    $locale = 'default' if $locale eq '';
    Send($s, 'pline', 0, [Msg('Locale', $locale)]);
  }
}

sub OnPlList {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  my $uch = $Users{$s}{channel};
  my $uclient = $Users{$s}{client};

  $page = ToInt($page, 1, undef);
  my $numnames = ToInt($Config->val('Command', 'PageList'), 1, 100);
  my $start = ($page - 1) * $numnames;
  my $last = $page * $numnames;

  my @display = ();
  my @length = (0,0,0,0,0,0,0);
  for (my $i=$start; $i<$last; $i++) {
    my $ch = $Channels[$i] or last;
    my $chno = $i + 1;
    $chno = ($uch eq $ch ? Msg($s, 'ColorChnoCurrent', $chno) : Msg($s, 'ColorChnoRegular', $chno));
    my $chname = ChannelName($ch);
    if ($uch eq $ch) {
      $chname = Msg($s, 'ColorChnameCurrent', $chname);
    } elsif (not $ch->{playable} or not $ch->{$uclient}) {
      $chname = Msg($s, 'ColorChnameUnplayable', $chname);
    } else {
      $chname = Msg($s, 'ColorChnameRegular', $chname);
    }
    my $players = NumberPlayers($ch);
    my $maxplayers = $ch->{maxplayers};
    my ($ingame, $paused) = (Msg($s, 'InGameDisplay'), Msg($s, 'PausedDisplay'));
    my $status = ' ' x (length($ingame) > length($paused) ? length($ingame) : length($paused));
    if ( $ch->{ingame} ) { $status = ($ch->{paused} ? $paused : $ingame); }
    my $priority = $ch->{priority};
    my $topic = $ch->{topic};

    my @fields = ($chno, $chname, $players, $maxplayers, $status, $priority, $topic);
    for (my $i=0; $i<@fields; $i++) {
      $length[$i] = max($length[$i], length($fields[$i]));
    }

    push(@display, [@fields]);
  }
  my $nextpage = (defined $Channels[$last]);

  Send($s, 'pline', 0, [Msg('ListingChannel')]);
  foreach (@display) {
    my @fields = @$_;
    my ($players, $maxplayers) = @fields[2..3];

    for (my $i=0; $i<@fields; $i++) {
      if ($i == 1) { # channel name
        $fields[$i] = sprintf("%-" . $length[$i] . "s", $fields[$i]);
      } elsif ($i == 6) { # topic
      } else {
        $fields[$i] = sprintf("%" . $length[$i] . "s", $fields[$i]);
      }
    }

    if ($players >= $maxplayers) {
      Send($s, 'pline', 0, [Msg('ListChannelFull', @fields)]);
    } else {
      Send($s, 'pline', 0, [Msg('ListChannelOpen', @fields)]);
    }
  }

  if ($nextpage) {
    my $next = COMMANDPREFIX . $cmd . ($page + 1);
    Send($s, 'pline', 0, [Msg('ListTooLong', $next)]);
  }
}

sub OnPlLmsg {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target, $message) = split(/ +/, $msg, 3);

  $target = StripColors($target);
  $message = StripColors($message);
  $message =~ s/^\s+//; $message =~ s/\s+$//;
  if ($target ne '' and $message ne '') {
    my $profile = GetPlayerProfile($target, MAXSTACKLEVEL);
    my $to = 'p' . lc($profile->[PF_PNAME]);
    my $from = StripColors($Users{$s}{nick});
    my $time = Time();
    AddLmsg($to, $from, $time, $message);
    Send($s, 'pline', 0, [Msg('LeftMessage', $target)]);
    Report('msg', $s, $s, "Left message to $target: <$from> $message");
  } else {
    SendCommandFormat($s, $cmd, 'lmsg');
  }
}

sub OnPlLoad {
  my ($s, $msg, $page) = @_;
  my ($cmd, $type) = split(/ +/, $msg);
  $type = '' unless defined $type;

  $type = lc $type;
  $type = 'message' if $type eq 'msg';
  my $result = undef;
  if ($type eq 'ban') {
    $result = ReadBan(undef);
  } elsif ($type eq 'config') {
    $result = ReadConfig(undef);
    if ($result) {
      UpdateChannels();
      WriteWinlist();
      ReadWinlist();
    }
  } elsif ($type eq 'message') {
    $result = ReadMsg(undef);
  } elsif ($type eq 'secure') {
    $result = ReadSecure(undef);
  } else {
    SendCommandFormat($s, $cmd, 'load');
    return;
  }

  if ( $result ) {
    Send($s, 'pline', 0, [Msg('LoadedConfiguration', $type)]);
    Report('admin', $s, $s, "$Users{$s}{nick} loaded $type configuration");
  } else {
    Send($s, 'pline', 0, [Msg('CouldNotLoadConfiguration', $type)]);
  }
}

sub OnPlMotd {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  SendFromFile($s, 'motd');
}

sub OnPlMove {
  my ($s, $msg, $page) = @_;
  my ($cmd, $slot, $newslot) = split(/ +/, $msg);
  $slot = '' unless defined $slot;
  $newslot = '' unless defined $newslot;

  my $ch = $Users{$s}{channel};

  ( Send($s, 'pline', 0, [Msg('UnavailableWhileInGame')]), return ) if $ch->{ingame};
  ( SendCommandFormat($s, $cmd, 'move'), return ) if $slot eq '';

  if ($slot eq '0') { # compact lower open slots
    ( Send($s, 'pline', 0, [Msg('CannotUseCommandNow')]), return ) if NumberReserved($ch) > 0;
    CompactPlayers($ch);
    SendToChannel($ch, 0, 'pline', 0, [Msg('CompactedPlayers', $Users{$s}{nick})]);
    Report('move', $s, $s, RMsgMove("$Users{$s}{nick} compacted slots", $ch));
    return;
  } elsif ($slot eq '8') { # shuffle players
    ( Send($s, 'pline', 0, [Msg('CannotUseCommandNow')]), return ) if NumberReserved($ch) > 0;
    ShufflePlayers($ch);
    SendToChannel($ch, 0, 'pline', 0, [Msg('ShuffledPlayers', $Users{$s}{nick})]);
    Report('move', $s, $s, RMsgMove("$Users{$s}{nick} shuffled slots", $ch));
    return;
  } elsif ($newslot eq '') {
    $newslot = $slot;
    $slot = $Users{$s}{slot};
  }

  $slot = ToInt($slot, undef, undef);
  $newslot = ToInt($newslot, undef, undef);

  my $ok1 = (1 <= $slot and $slot <= MAXPLAYERS);
  my $ok2 = (1 <= $newslot and $newslot <= MAXPLAYERS);
  ( SendCommandFormat($s, $cmd, 'move'), return ) unless ($ok1 and $ok2 and $slot != $newslot);

  ( Send($s, 'pline', 0, [Msg('CannotUseCommandNow')]), return ) if (defined $ch->{reserved}[$slot] or defined $ch->{reserved}[$newslot]);

  my $user1 = $ch->{players}[$slot];
  my $user2 = $ch->{players}[$newslot];
  if (not defined $user1 and defined $user2) {
    ($slot, $newslot) = ($newslot, $slot);
    ($user1, $user2) = ($user2, $user1);
  }
  if (defined $user1) {
    $ch->{players}[$slot] = $user2;
    $ch->{players}[$newslot] = $user1;

    SendPlayernum($user1, $newslot);
    SendToChannel($ch, $newslot, 'playerjoin', $newslot, $Users{$user1}{nick});
    SendToChannel($ch, $newslot, 'team', $newslot, $Users{$user1}{team});
    $Users{$user1}{slot} = $newslot;
    $Users{$user1}{field} = EmptyField();
    if (defined $user2) {
      SendPlayernum($user2, $slot);
      SendToChannel($ch, $slot, 'playerjoin', $slot, $Users{$user2}{nick});
      SendToChannel($ch, $slot, 'team', $slot, $Users{$user2}{team});
      $Users{$user2}{slot} = $slot;
      $Users{$user2}{field} = EmptyField();
    } else {
      SendToChannel($ch, 0, 'playerleave', $slot);
    }
    Report('move', $s, $s, RMsgMove("$Users{$s}{nick} moved slot $slot to $newslot", $ch));
  }
}

sub OnPlMsg {
  my ($s, $msg, $page) = @_;
  my ($cmd, $args) = split(/ +/, $msg, 2);
  $args = '' unless defined $args;

  my $ch = $Users{$s}{channel};
  my $message = '';
  my @targets = ();
  my $from = 0;
  my $sender;
  if ($Users{$s}{msgto} ne '') { # if msgto is set
    $message = $args;
    my $user = TargetNick($Users{$s}{msgto});
    push(@targets, $user) if defined $user;
    Send($s, 'pline', 0, [Msg('PlayerNotOnline', $Users{$s}{msgto})]) if not defined $user;
    $sender = $Users{$s}{nick};
  } else {
    my $target = '';
    ($target, $message) = split(/ +/, $args, 2);
    $target = StripColors($target);
    if ($target =~ /\D/) { # nick is specified
      my $user = TargetNick($target);
      push(@targets, $user) if defined $user;
      Send($s, 'pline', 0, [Msg('PlayerNotOnline', $target)]) if not defined $user;
      $sender = $Users{$s}{nick};
    } else { # number(s) is specified
      my %count;
      my @tmp = grep {1 <= $_ and $_ <= MAXPLAYERS and !$count{$_}++} split(//, $target);
      foreach my $slot (@tmp) {
        my $user = $ch->{players}[$slot];
        push(@targets, $user) if defined $user;
      }
      $from = $sender = $Users{$s}{slot};
    }
  }

  if ( scalar(@targets) and $message ne '' ) {
    foreach my $user (@targets) {
      next unless defined $Users{$user};
      Send($user, 'pline', $from, [Msg('Msg', $sender, $message)]);
      my $tonick = $Users{$user}{nick};
      Send($s, 'pline', 0, [Msg('SentPrivateMessage', $tonick)]);
      my $fromnick = $Users{$s}{nick};
      Report('msg', [$s, $user], $s, "Private message to $tonick: <$fromnick> $message");
    }
  } else {
    SendCommandFormat($s, $cmd, 'msg');
  }
}

sub OnPlMsgto {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);

  if (defined $target) {
    $Users{$s}{msgto} = $target;
    if ($target ne '') {
      Send($s, 'pline', 0, [Msg('SetMsgto', $target)]);
    } else {
      Send($s, 'pline', 0, [Msg('NoSetMsgto')]);
    }
  } else {
    SendCommandFormat($s, $cmd, 'msgto');
  }
}

sub OnPlNews {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  SendFromFile($s, 'news');
}

sub OnPlPasswd {
  my ($s, $msg, $page) = @_;
  my ($cmd, $pass) = split(/ +/, $msg);

  $pass = StripColors($pass);
  if ($pass ne '') {
    if ($Users{$s}{profile}[PF_PPASSWORD] eq '') {
      Send($s, 'pline', 0, [Msg('YouAreNotRegistered')]);
      return;
    }

    $Users{$s}{profile}[PF_PPASSWORD] = CryptPassword($pass);
    Send($s, 'pline', 0, [Msg('ChangedPassword')]);
    Report('profile', $s, $s, "$Users{$s}{nick} changed his/her password");
  } else {
    SendCommandFormat($s, $cmd, 'passwd');
  }
}

sub OnPlPause {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  my $ch = $Users{$s}{channel};

  ( Send($s, 'pline', 0, [Msg('GameIsNotBeingPlayed')]), return ) if not $ch->{ingame};

  if (not $ch->{paused}) {
    PauseGame($ch, $s);
  } elsif ($ch->{paused}) {
    UnpauseGame($ch, $s);
  }
}

sub OnPlPing {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  SendPlayernum($s, $Users{$s}{slot});
  $Users{$s}{playernum}[0]{pingmsg} = 1;
}

sub OnPlQuit {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  Report('connection', $s, $s, RMsgDisconnect("Quit", $s));
  CloseConnection($s);
}

sub OnPlReg {
  my ($s, $msg, $page) = @_;
  my ($cmd, $nick, $pass) = split(/ +/, $msg);

  $nick = StripColors($nick);
  $pass = StripColors($pass);
  if ($nick ne '' and $pass ne '') {
    my $profile = GetPlayerProfile($nick, 0);

    if ($profile->[PF_PPASSWORD] ne '') {
      Send($s, 'pline', 0, [Msg('NickAlreadyRegistered')]);
      return;
    }

    $profile->[PF_PPASSWORD] = CryptPassword($pass);
    Send($s, 'pline', 0, [Msg('Registered', $nick)]);
    Report('profile', $s, $s, "$Users{$s}{nick} registered $nick");
  } else {
    SendCommandFormat($s, $cmd, 'reg');
  }
}

sub OnPlReset {
  my ($s, $msg, $page) = @_;
  my ($cmd, @args) = split(/ +/, $msg);

  my $no = undef;
  my $backup = undef;
  foreach my $arg (@args) {
    next unless defined $arg;
    if ($arg =~ /^-/) {
      $arg = lc $arg;
      foreach my $opt ( split(//, $arg) ) {
        if ($opt eq '-') {
          # any `-' will be ignored
        } elsif ($opt eq 'b') {
          $backup = 1;
        } else {
          Send($s, 'pline', 0, [Msg('InvalidParameters')]);
          return;
        }
      }
    } else {
      $no = ($arg eq 'all' ? uc($arg) : ToInt($arg, 0, undef));
    }
  }

  if (defined $no) {
    my $result = undef;
    my @files = ();
    if ($no eq 'ALL') {
      ($result, @files) = ResetWinlistAll($backup);
    } else {
      ($result, @files) = ResetWinlist($no, $backup);
    }
    my $filename = join(', ', @files);
    if ($result) {
      Send($s, 'pline', 0, [Msg('ResetWinlistSucceeded', $no, $filename)]);
      Report('admin', $s, $s, "$Users{$s}{nick} reset winlist $no ($filename)");
    } else {
      Send($s, 'pline', 0, [Msg('ResetWinlistFailed', $no, $filename)]);
    }
  } else {
    SendWinlistList($s);
  }
}

sub OnPlSave {
  my ($s, $msg, $page) = @_;
  my ($cmd, $type) = split(/ +/, $msg);
  $type = '' unless defined $type;

  $type = lc $type;
  my $result = undef;
  if ($type eq 'ban') {
    $result = WriteBan();
    Report('ban', $s, $s, "$Users{$s}{nick} saved ban list") if $result;
  } else {
    SendCommandFormat($s, $cmd, 'save');
    return;
  }

  if ( $result ) {
    Send($s, 'pline', 0, [Msg('SavedConfiguration', $type)]);
    Report('admin', $s, $s, "$Users{$s}{nick} saved $type configuration");
  } else {
    Send($s, 'pline', 0, [Msg('CouldNotSaveConfiguration', $type)]);
  }
}

sub OnPlScore {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);
  $target = '' unless defined $target;

  my $ch = $Users{$s}{channel};

  my $wl = WinlistData($ch) or (
    Send($s, 'pline', 0, [Msg('NoScoring')]),
    return
  );

  my @targets = ();
  if ($target ne '') {
    push(@targets, "p$target", "t$target");
  } else {
    for (my $i=1; $i<=MAXPLAYERS; $i++) {
      my $user = $ch->{players}[$i] or next;
      push(@targets, 'p' . $Users{$user}{nick});
    }
  }

  foreach my $name (@targets) {
    my ($no, $wlname, $wlvalue) = Score($wl, undef, $name);
    next unless defined $no;
    $no++;
    my $type = substr($wlname, 0, 1);
    $wlname = substr($wlname, 1);

    if ($type eq 't') {
      $wlname = Msg('ColorMyname', $wlname) if (lc $wlname eq StripColors(lc $Users{$s}{team}));
      Send($s, 'pline', 0, [Msg('ListWinlistTeam', $no, $wlvalue, $wlname)]);
    } else {
      $wlname = Msg('ColorMyname', $wlname) if (lc $wlname eq StripColors(lc $Users{$s}{nick}));
      Send($s, 'pline', 0, [Msg('ListWinlistPlayer', $no, $wlvalue, $wlname)]);
    }
  }
}

sub OnPlSet {
  my ($s, $msg, $page) = @_;
  my ($cmd, $key, $values) = split(/ +/, $msg, 3);
  $key = '' unless defined $key;
  $values = '' unless defined $values;

  my $ch = $Users{$s}{channel};
  my $chname = ChannelName($ch);

  my $setable = $ch->{setable};
  if ( not CheckPermission($s, $setable) ) {
    Send($s, 'pline', 0, [Msg('NotSetable')]);
    return;
  }

  $key = lc $key;
  if ($key eq 'announce') {
    my @params = split(/ +/, $values);
    if (@params == 4) {
      ($ch->{announcerank}, $ch->{announcescore}, $ch->{announcestats}, $ch->{gamestatsmsg}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{announcerank}, $ch->{announcescore}, $ch->{announcestats}, $ch->{gamestatsmsg});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatAnnounce')]);
      my $cv = join(' ', $ch->{announcerank}, $ch->{announcescore}, $ch->{announcestats}, $ch->{gamestatsmsg});
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'basic') {
    my @params = split(/ +/, $values);
    if (@params == 4) {
      ($ch->{name}, $ch->{maxplayers}, $ch->{priority}, $ch->{persistant}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{name}, $ch->{maxplayers}, $ch->{priority}, $ch->{persistant});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatBasic')]);
      my $cv = join(' ',
        $ch->{name}, $ch->{maxplayers}, $ch->{priority}, $ch->{persistant}
      );
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'block') {
    my @params = split(/ +/, $values);
    if (@params == 7) {
      ($ch->{blockleftl}, $ch->{blockleftz}, $ch->{blocksquare}, $ch->{blockrightl},
          $ch->{blockrightz}, $ch->{blockhalfcross}, $ch->{blockline}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{blockleftl}, $ch->{blockleftz}, $ch->{blocksquare}, $ch->{blockrightl},
          $ch->{blockrightz}, $ch->{blockhalfcross}, $ch->{blockline});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatBlock')]);
      my $cv = join(' ',
        $ch->{blockleftl}, $ch->{blockleftz}, $ch->{blocksquare},
        $ch->{blockrightl}, $ch->{blockrightz}, $ch->{blockhalfcross}, $ch->{blockline}
      );
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'gametype') {
    my @params = split(/ +/, $values);
    if (@params == 4) {
      ($ch->{playable}, $ch->{tetrinet}, $ch->{tetrifast}, $ch->{gametype}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{playable}, $ch->{tetrinet}, $ch->{tetrifast}, $ch->{gametype});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatGametype')]);
      my $cv = join(' ',
        $ch->{playable}, $ch->{tetrinet}, $ch->{tetrifast}, $ch->{gametype}
      );
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'rules') {
    my @params = split(/ +/, $values);
    if (@params == 8) {
      ($ch->{startinglevel}, $ch->{linesperlevel}, $ch->{levelincrease}, $ch->{linesperspecial},
          $ch->{specialadded}, $ch->{specialcapacity}, $ch->{classicrules}, $ch->{averagelevels}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{startinglevel}, $ch->{linesperlevel}, $ch->{levelincrease}, $ch->{linesperspecial},
          $ch->{specialadded}, $ch->{specialcapacity}, $ch->{classicrules}, $ch->{averagelevels});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatRules')]);
      my $cv = join(' ',
        $ch->{startinglevel}, $ch->{linesperlevel}, $ch->{levelincrease}, $ch->{linesperspecial},
        $ch->{specialadded}, $ch->{specialcapacity}, $ch->{classicrules}, $ch->{averagelevels}
      );
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
      Send($s, 'pline', 0, [Msg('SetFormatStack')]);
      Send($s, 'pline', 0, [Msg('CurrentSettings', $ch->{stack})]);
    }
  } elsif ($key eq 'sd') {
    my @params = split(/ +/, $values);
    if (@params == 3) {
      ($ch->{sdtimeout}, $ch->{sdlinesperadd}, $ch->{sdsecsbetweenlines}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{sdtimeout}, $ch->{sdlinesperadd}, $ch->{sdsecsbetweenlines});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatSd')]);
      my $cv = join(' ', $ch->{sdtimeout}, $ch->{sdlinesperadd}, $ch->{sdsecsbetweenlines});
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
      Send($s, 'pline', 0, [Msg('SetFormatSdmsg')]);
      $cv = ($ch->{sdmessage} ne '' ? $ch->{sdmessage} : '-');
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'sdmsg') {
    my $param = $values;
    if ($param ne '') {
      $ch->{sdmessage} = $param;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{sdmessage});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatSdmsg')]);
      my $cv = ($ch->{sdmessage} ne '' ? $ch->{sdmessage} : '-');
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'special') {
    my @params = split(/ +/, $values);
    if (@params == 9) {
      ($ch->{specialaddline}, $ch->{specialclearline}, $ch->{specialnukefield},
          $ch->{specialrandomclear}, $ch->{specialswitchfield}, $ch->{specialclearspecial},
          $ch->{specialgravity}, $ch->{specialquakefield}, $ch->{specialblockbomb}) = @params;
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{specialaddline}, $ch->{specialclearline}, $ch->{specialnukefield},
          $ch->{specialrandomclear}, $ch->{specialswitchfield}, $ch->{specialclearspecial},
          $ch->{specialgravity}, $ch->{specialquakefield}, $ch->{specialblockbomb});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatSpecial')]);
      my $cv = join(' ',
        $ch->{specialaddline}, $ch->{specialclearline}, $ch->{specialnukefield},
        $ch->{specialrandomclear}, $ch->{specialswitchfield}, $ch->{specialclearspecial},
        $ch->{specialgravity}, $ch->{specialquakefield}, $ch->{specialblockbomb}
      );
      Send($s, 'pline', 0, [Msg('CurrentSettings', $cv)]);
    }
  } elsif ($key eq 'stack') {
    my @params = split(/ +/, $values);
    if (@params == 6) {
      $ch->{stack} = join(' ', @params);
      NormalizeChannelConfig($ch);
      my $settings = join(' ', $ch->{stack});
      SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedSettings', $Users{$s}{nick}, uc($key), $settings)]);
      Report('set', $s, $s, RMsgSet($chname, $s, $key, $settings));
    } else {
      Send($s, 'pline', 0, [Msg('SetFormatStack')]);
      Send($s, 'pline', 0, [Msg('CurrentSettings', $ch->{stack})]);
    }
  } else {
    Send($s, 'pline', 0, [Msg('SetHelp')]);
    foreach ( qw[announce basic block gametype rules sd special] ) {
      my $key = ucfirst lc $_;
      Send($s, 'pline', 0, [' ' x 2, Msg("SetHelp$key")]);
    }
  }
}

sub OnPlShutdown {
  my ($s, $msg, $page) = @_;
  my ($cmd, $arg) = split(/ +/, $msg);
  $arg = '' unless defined $arg;

  my $cancel = undef;
  my $haltnow = undef;
  my $relaunch = undef;
  if ($arg =~ /^-/) {
    foreach my $opt ( split(//, $arg) ) {
      $opt = lc $opt;
      if ($opt eq '-') {
        # any `-' will be ignored
      } elsif ($opt eq 'c') {
        $cancel = 1;
      } elsif ($opt eq 'n') {
        $haltnow = 1;
      } elsif ($opt eq 'r') {
        $relaunch = 1;
      } else {
        Send($s, 'pline', 0, [Msg('InvalidParameters')]);
        return;
      }
    }
  }

  if ($cancel) {
    if ( IsSetShutdown() ) {
      Report('admin', $s, $s, "$Users{$s}{nick} canceled to shut down the server");
      SendToAll('pline', 0, [Msg('ServerStoppedToDown')]);
      CancelShutdown();
    } else {
      Send($s, 'pline', 0, [Msg('ServerNotGoingToDown')]);
    }
  } else {
    Report('admin', $s, $s, "$Users{$s}{nick} requested to shut down the server");
    if ($haltnow) {
      StopServer($relaunch);
    } else {
      SendToAll('pline', 0, [Msg('ServerDownWhenCurrentGamesEnded')]) unless IsServerStoppable();
      SetShutdown($relaunch);
    }
  }
}

sub OnPlStart {
  my ($s, $msg, $page) = @_;
  my ($cmd, $count) = split(/ +/, $msg);
  $count = '' unless defined $count;

  my $ch = $Users{$s}{channel};
  if ( IsSetStartingCount($ch) ) {
    RemoveStartingCount($ch);
    SendToChannel($ch, 0, 'pline', 0, [Msg('StartingCountStopped')]);
    return;
  }
  ( Send($s, 'pline', 0, [Msg('UnavailableWhileInGame')]), return ) if $ch->{ingame};
  ( Send($s, 'pline', 0, [Msg('GameCurrentlyUnavailable')]), return ) if IsSetShutdown();
  ( Send($s, 'pline', 0, [Msg('NotPlayable')]), return ) unless $ch->{playable};

  $count = $Config->val('Command', 'DefaultStartCount') if $count eq '';
  $count = ToInt($count);
  $count = MAXSTARTINGCOUNT if $count > MAXSTARTINGCOUNT;

  if ($count <= 0) {
    StartGame($ch, $s);
  } else {
    SendToChannel($ch, 0, 'pline', 0, [Msg('GameStarted', $Users{$s}{nick})]);
    SetStartingCount($ch, $count);
    SendToChannel($ch, 0, 'pline', 0, [Msg('StartingCountStarted', $count)]);
  }
}

sub OnPlStop {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  my $ch = $Users{$s}{channel};

  ( Send($s, 'pline', 0, [Msg('GameIsNotBeingPlayed')]), return ) if not $ch->{ingame};

  EndGame($ch, $s);
}

sub OnPlTeleport {
  my ($s, $msg, $page) = @_;
  my ($cmd, $tnick, $tch) = split(/ +/, $msg);
  $tch = '' unless defined $tch;

  my $user = TargetNick($tnick);
  if (defined $user) {
    my $ch = ($tch ne '' ? TargetChannel($tch) : $Users{$s}{channel});
    if (not defined $ch) {
      Send($s, 'pline', 0, [Msg('ChannelNotExists')]);
      return;
    }
    if ( not defined OpenSlot($ch) ) {
      Send($s, 'pline', 0, [Msg('ChannelIsFull')]);
      return;
    }

    my $chname = ChannelName($ch);
    Send($s, 'pline', 0, [Msg('Teleported', $Users{$user}{nick}, $chname)]);
    Send($user, 'pline', 0, [Msg('GotTeleported', $Users{$s}{nick}, $chname)]);

    my $prevch = $Users{$s}{channel};
    my $fromname = ChannelName($prevch);
    my $slot = OpenSlot($ch);
    Report('join', $s, $s, "$Users{$s}{nick} forced $Users{$user}{nick} to join channel $chname / $slot from $fromname");

    JoinChannel($user, $ch, 0);
    GarbageChannel($prevch);
  } else {
    SendCommandFormat($s, $cmd, 'teleport');
  }
}

sub OnPlTime {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  Send($s, 'pline', 0, [Msg('Time', scalar localtime( Time() ))]);
}

sub OnPlTopic {
  my ($s, $msg, $page) = @_;
  my ($cmd, $topic) = split(/ +/, $msg, 2);

  if (defined $topic) {
    my $ch = $Users{$s}{channel};
    $ch->{topic} = $topic;
    NormalizeChannelConfig($ch);
    SendToChannel($ch, 0, 'pline', 0, [Msg('ChangedTopic', $Users{$s}{nick}, $ch->{topic})]);

    my $chname = ChannelName($ch);
    Report('set', $s, $s, "[$chname] $Users{$s}{nick} changed topic to $ch->{topic}");
  } else {
    SendCommandFormat($s, $cmd, 'topic');
  }
}

sub OnPlUnban {
  my ($s, $msg, $page) = @_;
  my ($cmd, $nick, $host) = split(/ +/, $msg);
  $nick = '' unless defined $nick;
  $host = '' unless defined $host;

  if ($nick eq '') {
    Send($s, 'pline', 0, [Msg('ListingBan')]);
    SendBanList($s);
  } else {
    unless ($nick ne '' and $host ne '') {
      SendCommandFormat($s, $cmd, 'unban');
      return;
    }

    my $result = RemoveBanRawData($nick, $host);
    if ($result) {
      RemoveBanData($nick, $host);
      my $opts = ($result->[0] ne '' ? $result->[0] : '-');
      my $mask = "$opts $nick $host";
      Send($s, 'pline', 0, [Msg('UnbannedUser', $mask)]);
      Report('ban', $s, $s, "$Users{$s}{nick} removed ban mask: $mask");
    } else {
      Send($s, 'pline', 0, [Msg('NoSuchBanMask')]);
    }
  }
}

sub OnPlUnreg {
  my ($s, $msg, $page) = @_;
  my ($cmd, $nick) = split(/ +/, $msg);

  $nick = StripColors($nick);
  if ($nick ne '') {
    if ( not DefinedPlayerProfile($nick) ) { # for not to make entry
      Send($s, 'pline', 0, [Msg('NickNotRegistered')]);
      return;
    }

    my $profile = GetPlayerProfile($nick, 0);

    if ($profile->[PF_PPASSWORD] eq '') {
      Send($s, 'pline', 0, [Msg('NickNotRegistered')]);
      return;
    }

    $profile->[PF_PPASSWORD] = '';
    Send($s, 'pline', 0, [Msg('Unregistered', $nick)]);
    Report('profile', $s, $s, "$Users{$s}{nick} unregistered $nick");
  } else {
    SendCommandFormat($s, $cmd, 'unreg');
  }
}

sub OnPlVersion {
  my ($s, $msg, $page) = @_;
  my ($cmd) = split(/ +/, $msg, 2);

  Send($s, 'pline', 0, [Msg('Version', $PROGRAM_NAME)]);
}

sub OnPlWho {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);
  $target = '' unless defined $target;

  if ($target ne '') {
  # list players on specified channel
    my $ch = TargetChannel($target);
    if (not defined $ch) {
      Send($s, 'pline', 0, [Msg('ChannelNotExists')]);
      return;
    }

    Send($s, 'pline', 0, [Msg('ListingWhoOne')]);
    for (my $i=1; $i<=MAXPLAYERS; $i++) {
      my $user = $ch->{players}[$i] or next;
      my $nick = $Users{$user}{nick};
      my $nlen = 8 - length(StripColors($nick));
      $nick .= ' ' x $nlen if $nlen > 0;
      $nick = Msg('ColorMyname', $nick) if $Users{$user}{nick} eq $Users{$s}{nick};
      my $team = $Users{$user}{team};
      my $tlen = 8 - length(StripColors($team));
      $team .= ' ' x $tlen if $tlen > 0;
      my ($ip, $host) = ($Users{$user}{ip}, $Users{$user}{host}) if CheckPermission($s, $Config->val('Command', 'DisplayIP'));
      Send($s, 'pline', 0, [Msg('WhoOnePlayer', $i, $nick, $team, $ip, $host)]);
    }
  } else {
  # list all players
    Send($s, 'pline', 0, [Msg('ListingWhoAll')]);
    my $onlineplayers = 0;
    for (my $i=0; $i<@Channels; $i++) {
      my $ch = $Channels[$i];
      my $chno = $i + 1;
      my $chname = ChannelName($ch);
      my $players = '';
      foreach my $user (@{$ch->{players}}) {
        next unless defined $user;
        my $nick = $Users{$user}{nick};
        $nick = Msg('ColorMyname', $nick) if $user eq $s;
        $players .= Msg($s, 'WhoAllPlayer', $nick, $Users{$user}{team}) . ' ';
        $onlineplayers++;
      }
      Send($s, 'pline', 0, [Msg('WhoAllChannel', $chno, $chname, $players)]) if $players ne '';
    }
    Send($s, 'pline', 0, [Msg('WhoAllOnlinePlayers', $onlineplayers)]);
  }
}

sub OnPlWinlist {
  my ($s, $msg, $page) = @_;
  my ($cmd, $target) = split(/ +/, $msg);
  $target = '' unless defined $target;

  my $ch = undef;
  if ($target ne '') {
    $ch = TargetChannel($target);
    if (not defined $ch) {
      Send($s, 'pline', 0, [Msg('ChannelNotExists')]);
      return;
    }
  } else {
    $ch = $Users{$s}{channel};
  }
  $page = ToInt($page, 1, undef);

  my $wl = WinlistData($ch) or (
    Send($s, 'pline', 0, [Msg('NoScoring')]),
    return
  );

  my $numnames = ToInt($Config->val('Command', 'PageWinlist'), 1, 100);
  my $start = ($page - 1) * $numnames;
  my $last = $page * $numnames;
  Send($s, 'pline', 0, [Msg('ListingWinlist', $start + 1, $last)]);

  my $format = undef;
  for (my $i=$start; $i<$last; $i++) {
    my ($no, $name, $value) = Score($wl, $i, undef);
    last unless defined $no;
    my $type = substr($name, 0, 1);
    $name = substr($name, 1);

    $value = round($value, SCOREDECIMAL);
    my ($int, $dec) = split(/\./, $value, 2);
    $format = "%" . length($int) . "d.%-" . SCOREDECIMAL . "d" if not defined $format;
    $value = sprintf($format, $int, $dec);

    my $rank = sprintf("%" . length($last) . "d", $no + 1);
    if ($type eq 't') {
      $name = Msg('ColorMyname', $name) if (lc $name eq StripColors(lc $Users{$s}{team}));
      Send($s, 'pline', 0, [Msg('ListWinlistTeam', $rank, $value, $name)]);
    } else {
      $name = Msg('ColorMyname', $name) if (lc $name eq StripColors(lc $Users{$s}{nick}));
      Send($s, 'pline', 0, [Msg('ListWinlistPlayer', $rank, $value, $name)]);
    }
  }
  my ($nextpage) = Score($wl, $last, undef);

  if (defined $nextpage) {
    my $next = COMMANDPREFIX . $cmd . ($page + 1);
    Send($s, 'pline', 0, [Msg('ListTooLong', $next)]);
  }
}

# =================================================================
#     Authority/Permission functions
# =================================================================

sub AuthorityLevel {
  my ($s) = @_;
  return 0 unless defined $Users{$s}{profile};

  my $auth = $Users{$s}{profile}[PF_PAUTHORITY];

  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};
  if (ModeratorSlot($ch) == $slot) {
    my $authmod = $Config->val('Authority', 'Moderator');
    $auth = max($auth, $authmod);
  }

  $auth = ToInt($auth, 0, undef);
  return $auth;
}

sub CheckCommandPermission {
  my ($s, $cmd, $retcol) = @_;

  $cmd = ucfirst lc $cmd;
  my $perm = $Config->val('Command', $cmd);
  $perm = -1 if not defined $perm;

  if ( CheckPermission($s, $perm) ) {
    return ($retcol ? Msg('ColorCommandUsable') : 1);
  } else {
    if (not $retcol) {
      my $msg = ($perm >= 0 ? Msg('NoPermissionToCommand') : Msg('InvalidCommand'));
      Send($s, 'pline', 0, [$msg]);
    }
    return ($retcol ? Msg('ColorCommandUnusable') : undef);
  }
}

sub CheckPermission {
  my ($s, $perm) = @_;

  my $auth = AuthorityLevel($s);
  return undef if $perm < 0; # disable

  return ($perm <= $auth ? 1 : undef);
}

sub AuthorityLevel_ston {
  my ($level) = @_;
  return '' if (not defined $level or $level eq '');

  $level = lc $level;
  $level = $Config->val('Authority', 'User') if $level eq 'user';
  $level = $Config->val('Authority', 'Operator') if $level eq 'op';
  $level = $Config->val('Authority', 'Administrator') if $level eq 'admin';

  return $level;
}

# =================================================================
#     Game functions
# =================================================================

sub StartGame {
  my ($ch, $s) = @_;
  return if $ch->{ingame};

  RemoveStartingCount($ch);

  if ( IsSetShutdown() ) {
    defined $s ? Send($s, 'pline', 0, [Msg('GameCurrentlyUnavailable')]) : SendToChannel($ch, 0, 'pline', 0, [Msg('GameCurrentlyUnavailable')]);
    return;
  }

  if (not $ch->{playable}) {
    defined $s ? Send($s, 'pline', 0, [Msg('NotPlayable')]) : SendToChannel($ch, 0, 'pline', 0, [Msg('NotPlayable')]);
    return;
  }

  my ($blocks, $specials) = BlockFrequency($ch);
  if ( length($blocks) != 100 or length($specials) != 100 ) {
    defined $s ? Send($s, 'pline', 0, [Msg('FrequencyMustAddUpTo100')]) : SendToChannel($ch, 0, 'pline', 0, [Msg('FrequencyMustAddUpTo100')]);
    return;
  }

  SendToChannel($ch, 0, 'pline', 0, [Msg('GameStarted', $Users{$s}{nick})]) if defined $s;

  my @start = (); # players at start
  my @spectators = (); # spectators and players not allowed to play game
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    my $team = $Users{$user}{team};
    my $lcteam = lc $team;
    my @names = split(/ +/, lc $Config->val('Main', 'SpecTeamName'));
    if ( $team ne '' and grep {$_ eq $lcteam} @names ) {
      push(@spectators, $user);
    } elsif ( ($ch->{tetrinet} and $Users{$user}{client} eq CLIENT_TETRINET)
        or ($ch->{tetrifast} and $Users{$user}{client} eq CLIENT_TETRIFAST) ) {
      push(@start, [$user, $Users{$user}{nick}, $team]);
    } else {
      push(@spectators, $user);
    }
  }
  if (not @start) {
    defined $s ? Send($s, 'pline', 0, [Msg('NoOneIsAllowedToPlayGame')]) : SendToChannel($ch, 0, 'pline', 0, [Msg('NoOneIsAllowedToPlayGame')]);
    return;
  }

  my $chname = ChannelName($ch);
  Report('game', $s, $s, "[$chname] Game has been started");

  $Daily{games}++;

  # game initialization
  $ch->{ingame} = 1;
  $ch->{paused} = 0;

  $ch->{game} = {};
  $ch->{game}{players} = [];
  $ch->{game}{start} = \@start; # players at start
  ResetGameTime($ch);

  foreach ( qw[gametype stack startinglevel linesperlevel levelincrease
               linesperspecial specialadded specialcapacity classicrules averagelevels
               sdtimeout sdlinesperadd sdsecsbetweenlines sdmessage
               blockleftl blockleftz blocksquare blockrightl blockrightz blockhalfcross blockline
               specialaddline specialclearline specialnukefield specialrandomclear specialswitchfield
               specialclearspecial specialgravity specialquakefield specialblockbomb] ) {
    $ch->{game}{$_} = $ch->{$_};
  }

  foreach (@start) {
    my ($user, $nick, $team) = @$_;
    $Users{$user}{alive} = 1;
    $Users{$user}{gs} = {InitialGameStats(), gamestate => 1};
    SetTimeoutIngame($user);
  }

  SetSuddenDeath($ch);

  foreach my $user (@spectators) {
    my $slot = $Users{$user}{slot};
    SendToChannel($ch, $slot, 'playerleave', $slot);
  }

  # send newgame
  my @stack = split(/\s+/, $ch->{stack});
  foreach (@start) {
    my $user = $_->[0];
    my $slot = $Users{$user}{slot};
    Send($user, Newgame($user),
        $stack[$slot-1],
        $ch->{startinglevel}, $ch->{linesperlevel}, $ch->{levelincrease},
        $ch->{linesperspecial}, $ch->{specialadded}, $ch->{specialcapacity},
        $blocks, $specials,
        $ch->{averagelevels}, $ch->{classicrules}
    );
  }

  foreach my $user (@spectators) {
    my $slot = $Users{$user}{slot};
    SendPlayernum($user, $slot);
    Send($user, 'ingame');
    Send($user, 'pause', ($ch->{paused} ? 1 : 0));
    Send($user, 'playerlost', $slot);
    SendToChannel($ch, $slot, 'playerjoin', $slot, $Users{$user}{nick});
    SendToChannel($ch, $slot, 'team', $slot, $Users{$user}{team});
    SendToChannel($ch, $slot, 'playerlost', $slot);
  }
}

sub PauseGame {
  my ($ch, $s) = @_;

  my $chname = ChannelName($ch);
  Report('game', $s, $s, "[$chname] Game has been paused");

  PauseGameTime($ch);
  PauseTimeoutIngame($ch);
  PauseSuddenDeath($ch);
  $ch->{paused} = 1;
  SendToChannel($ch, 0, 'pause', 1);
  SendToChannel($ch, 0, 'gmsg', [Msg('GamePaused', $Users{$s}{nick})]);
}

sub UnpauseGame {
  my ($ch, $s) = @_;

  my $chname = ChannelName($ch);
  Report('game', $s, $s, "[$chname] Game has been unpaused");

  UnpauseGameTime($ch);
  UnpauseTimeoutIngame($ch);
  UnpauseSuddenDeath($ch);
  $ch->{paused} = 0;
  SendToChannel($ch, 0, 'pause', 0);
  SendToChannel($ch, 0, 'gmsg', [Msg('GameUnpaused', $Users{$s}{nick})]);
}

sub EndGame {
  my ($ch, $stopped) = @_;
  return unless $ch->{ingame};

  $ch->{ingame} = 0;
  $ch->{paused} = 0;
  RemoveSuddenDeath($ch);

  SendToChannel($ch, 0, 'endgame');

  my $chname = ChannelName($ch);
  if (defined $stopped) {
    SendToChannel($ch, 0, 'pline', 0, [Msg('GameStopped', $Users{$stopped}{nick})]);
    Report('game', $stopped, $stopped, "[$chname] Game has been stopped");
  } else {
    Report('game', undef, undef, "[$chname] Game has been ended");

    my ($rank, $score) = WinlistCalculate($ch);
    SendToChannel($ch, 0, 'winlist', Winlist($ch));

    AnnounceRank($ch, $rank);
    AnnounceScore($ch, $score);
    AnnounceStats($ch, $ch->{game}{players}, undef) if $ch->{announcestats};
  }
}

sub CheckGameEnd {
  my ($ch) = @_;
  return unless $ch->{ingame};

  my %alive = ();
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    next unless $Users{$user}{alive};
    my $team = $Users{$user}{team};
    if ($team eq '') {
      my $lcnick = lc $Users{$user}{nick};
      $alive{"p$lcnick"} = [];
      push(@{$alive{"p$lcnick"}}, $user);
    } else {
      my $lcteam = lc $team;
      $alive{"t$lcteam"} = [] if not defined $alive{"t$lcteam"};
      push(@{$alive{"t$lcteam"}}, $user);
    }
  }
  my $numalive = scalar(keys %alive); # the number of alive teams (players)

  if ( $numalive == 0 # a one-player game or self-survival game has been ended
       or ($numalive == 1 and @{$ch->{game}{start}} > 1 and $ch->{game}{gametype} != 2) ) {
    SetGameTimeEnd($ch);

    my $wplayers = (values %alive)[0]; # winner players
    if (defined $wplayers) {
      AddPlayerGameInfo($ch, $_) foreach (@$wplayers);
      my $wuser = $wplayers->[0];
      SendToChannel($ch, 0, 'playerwon', $Users{$wuser}{slot});
    }

    EndGame($ch, undef);
  } else {
    # game continues...
  }
}

sub AddPlayerGameInfo {
  my ($ch, $s) = @_;

  $Users{$s}{alive} = undef;
  $Users{$s}{gs}{lifetime} = GameTime($ch);
  SetGameStatsFromLast($s) if $Users{$s}{timedout};
  my $sbgiven = scalar @{$Users{$s}{gs}{sbgiven}};
  $Users{$s}{gs}{pieces} -= $sbgiven;
  $Users{$s}{gs}{lines} -= $sbgiven;
  $Users{$s}{gs}{ud} = $sbgiven;
  $Users{$s}{gs}{sbgiven} = [];

  my $nick = $Users{$s}{nick};
  my $lcnick = lc $nick;

  # does the player played the game?
  my $ok = 0;
  foreach ( @{$ch->{game}{start}} ) {
    my ($user, $nick2, $team) = @$_;
    ($ok = 1, last) if ($lcnick eq lc $nick2);
  }
  return undef unless $ok;

  # already added?
  foreach ( @{$ch->{game}{players}} ) {
    return undef if ($lcnick eq lc $_->{nick});
  }

  if ( not PlayedGame($s) ) {
    # actually player did not play the game
    for (my $i=0; $i<@{$ch->{game}{start}}; $i++) {
      my ($user, $nick2, $team) = @{$ch->{game}{start}[$i]};
      (splice(@{$ch->{game}{start}}, $i, 1), last) if ($lcnick eq lc $nick2);
    }
    return undef;
  }

  my $team = $Users{$s}{team};
  my $name = ($team ne '' ? "t$team" : "p$nick");
  my %info = (
    nick => $nick, team => $team, name => $name,
    csadded => $Users{$s}{gs}{csadded},
    lifetime => $Users{$s}{gs}{lifetime},
    lines => $Users{$s}{gs}{lines},
    pieces => $Users{$s}{gs}{pieces},
    specials => $Users{$s}{gs}{specials},
    tetris => $Users{$s}{gs}{tetris},
    ud => $Users{$s}{gs}{ud},
  );
  unshift(@{$ch->{game}{players}}, \%info);

  $Users{$s}{profile}[PF_PGAMES]++;

  return 1;
}

sub AnnounceRank {
  my ($ch, $rank) = @_;

  return undef unless $ch->{announcerank};
  return undef unless defined $rank;
  return undef unless (scalar @$rank > 1);

  my @tmp = ();
  for (my $i=0; $i<$ch->{announcerank}; $i++) {
    last unless defined $rank->[$i];
    my $plinfo = $rank->[$i][0];
    my $name = $plinfo->{name};
    my $type = (substr($name, 0, 1) eq 't' ? '<T>' : '');
    $name = substr($name, 1);
    my $no = $i + 1;
    push(@tmp, Msg('AnnounceRank', $no, $type, $name), '  ');
  }

  for (my $i=0; $i<MAXPLAYERS; $i+=3) {
    my @msg = splice(@tmp, 0, 6);
    pop(@msg);
    SendToChannel($ch, 0, 'pline', 0, [@msg]) if (scalar @msg > 0);
  }

  return 1;
}

sub AnnounceScore {
  my ($ch, $score) = @_;
  return undef unless $ch->{announcescore};
  return undef unless defined $score;

  my @display = ();
  my @length = (0,0,0,0,0,0,0);
  foreach (@$score) {
    my ($wltype, $name, $value, $rank, $increase) = @$_;

    my $type = substr($name, 0, 1);
    $name = substr($name, 1);
    my $sign = ($increase >= 0 ? '+' : '-');

    my @fields = ($wltype, $sign, $type, $name, $value, $increase, $rank);
    for (my $i=0; $i<@fields; $i++) {
      $length[$i] = max($length[$i], length($fields[$i]));
    }

    push(@display, [@fields]);
  }

  foreach (@display) {
    my @fields = @$_;

    for (my $i=0; $i<@fields; $i++) {
      if ($i == 0 or $i == 1 or $i == 2) { # wltype, sign, type
      } elsif ($i == 3) { # name
        $fields[$i] = sprintf("%-" . $length[$i] . "s", $fields[$i]);
      } else {
        $fields[$i] = sprintf("%" . $length[$i] . "s", $fields[$i]);
      }
    }

    my $wltype = shift @fields;
    my $sign = shift @fields;
    my $type = shift @fields;
    $fields[0] = ($type eq 't' ? Msg('ColorScoreTeam', $fields[0]) : Msg('ColorScorePlayer', $fields[0]));
    $fields[2] = $sign . $fields[2];

    SendToChannel($ch, 0, 'pline', 0, [Msg("AnnounceScore$wltype", @fields)]);
  }

  return 1;
}

sub AnnounceStats {
  my ($ch, $data, $s) = @_;

  my $gametime = GameTime($ch);
  defined $s ? Send($s, 'pline', 0, [Msg('AnnounceGameStats', $gametime)]) : SendToChannel($ch, 0, 'pline', 0, [Msg('AnnounceGameStats', $gametime)]);

  my @display = ();
  my @length = (0,0,0,0,0,0,0,0,0,0);
  foreach my $plinfo (@$data) {
    my $nick = $plinfo->{nick};
    my $lifetime = round($plinfo->{lifetime}, SCOREDECIMAL);
    next unless $lifetime > 0;
    my $pieces = $plinfo->{pieces};
    my $ud = $plinfo->{ud};
    my $ppm = round((60 * $pieces) / $lifetime, SCOREDECIMAL); # pieces per minute
    my $specials = $plinfo->{specials};

    my $lines = $plinfo->{lines};
    my $tetris = $plinfo->{tetris};
    my $csadded = $plinfo->{csadded};
    my $yields = ($lines > 0 ? round((100 * $csadded) / $lines, 0) : '-'); # percentage of (added lines / cleared lines)
    if (not $ch->{game}{classicrules}) {
      $lines = $tetris = $csadded = $yields = '-';
    }

    my @fields = ($nick, $lifetime, $pieces, $ud, $ppm, $specials, $lines, $tetris, $csadded, $yields);
    for (my $i=0; $i<@fields; $i++) {
      $length[$i] = max($length[$i], length($fields[$i]));
    }

    push(@display, [@fields]);
  }

  my $msgno = $ch->{gamestatsmsg};
  foreach (@display) {
    my @fields = @$_;

    for (my $i=0; $i<@fields; $i++) {
      if ($i == 0) { # nick
        $fields[$i] = sprintf("%-" . $length[$i] . "s", $fields[$i]);
      } else {
        $fields[$i] = sprintf("%" . $length[$i] . "s", $fields[$i]);
      }
    }

    defined $s ? Send($s, 'pline', 0, [Msg("AnnouncePlayerStats$msgno", @fields)]) : SendToChannel($ch, 0, 'pline', 0, [Msg("AnnouncePlayerStats$msgno", @fields)]);
  }

  return 1;
}

sub InitialGameStats {
  return (
    csadded => 0,
    gamestate => 0,
    last => {InitialGameStatsLast()},
    lifetime => 0,
    lines => 0,
    pieces => 0,
    prev => {InitialGameStatsPrev()},
    sbgiven => [],
    specials => 0,
    tetris => 0,
    ud => 0,
  );
}

sub InitialGameStatsPrev {
  return (
    lines => 0,
    pieces => 0,
    sbgiven => '',
  );
}

sub InitialGameStatsLast {
  return (
    csadded => 0,
    lifetime => 0,
    lines => 0,
    pieces => 0,
    sbgiven => [],
    specials => 0,
    tetris => 0,
    ud => 0,
  );
}

sub UpdateGameStatsLast {
  my ($s) = @_;
  my $ch = $Users{$s}{channel};
  return unless ($ch->{ingame} and $Users{$s}{alive});

  $Users{$s}{gs}{last} = {
    csadded => $Users{$s}{gs}{csadded},
    lifetime => GameTime($ch),
    lines => $Users{$s}{gs}{lines},
    pieces => $Users{$s}{gs}{pieces},
    sbgiven => [ @{$Users{$s}{gs}{sbgiven}} ],
    specials => $Users{$s}{gs}{specials},
    tetris => $Users{$s}{gs}{tetris},
  };
}

sub SetGameStatsFromLast {
  my ($s) = @_;

  foreach ( qw[csadded lifetime lines pieces sbgiven specials tetris] ) {
    $Users{$s}{gs}{$_} = $Users{$s}{gs}{last}{$_};
  }
}

sub GameStatsOnF {
  my ($s, $old, $new, $field) = @_;

  $Users{$s}{gs}{prev} = {InitialGameStatsPrev()};
  if ($Users{$s}{gs}{gamestate} == 1) { # initialization
    $Users{$s}{gs}{gamestate} = 0;
  } elsif ($Users{$s}{gs}{gamestate} == 2) { # cs* - lines already counted
    $Users{$s}{gs}{pieces}++;
    $Users{$s}{gs}{gamestate} = 0;
  } elsif ($Users{$s}{gs}{gamestate} == 3) { # he used sb to himself
    $Users{$s}{gs}{gamestate} = 0;
  } else {
    if ( not CheckSbgiven($s, $old, $new, $field) ) {
      if (length($field) == FIELD_HEIGHT * FIELD_WIDTH and $field =~ /^[\x30-\x73]/) {
        if ($field =~ /\x30/) { # \x30 = blank block
        # cleared line
          $Users{$s}{gs}{pieces}++; $Users{$s}{gs}{prev}{pieces} = 1;
          $Users{$s}{gs}{lines}++; $Users{$s}{gs}{prev}{lines} = 1;
        } else {
        # player died
        }
      } else {
        $Users{$s}{gs}{pieces}++; $Users{$s}{gs}{prev}{pieces} = 1;
        if ($field =~ /\x21/) { # \x21 = blank block type
          $Users{$s}{gs}{lines}++; $Users{$s}{gs}{prev}{lines} = 1;
        }
      }
    }
  }
}

sub CheckSbgiven {
  my ($s, $old, $new, $field) = @_;

  my $sbgiven = shift @{$Users{$s}{gs}{sbgiven}};
  return undef unless defined $sbgiven;

  my $issb = 1;
  if ($field eq '') {
    # $issb = 1;
  } elsif ($sbgiven =~ /^cs(\d+)$/) {
    my $num = ToInt($1, 1, 4);
    for (my $y=$num; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if $old->[$x][$y] != $new->[$x][$y-$num];
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'a') {
    for (my $y=1; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if $old->[$x][$y] != $new->[$x][$y-1];
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'c') {
    for (my $y=1; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if $old->[$x][$y-1] != $new->[$x][$y];
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'n') {
    for (my $y=0; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if $new->[$x][$y] != 0;
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'r') {
    $issb = undef if $field !~ /\x21/; # blank block designater
  } elsif ($sbgiven eq 's') {
  } elsif ($sbgiven eq 'b') {
    for (my $y=0; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if (6 <= $new->[$x][$y] and $new->[$x][$y] <= 14); # if there are special blocks
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'g') {
    for (my $x=0; $x<FIELD_WIDTH; $x++) {
      my $block = undef;
      for (my $y=0; $y<FIELD_HEIGHT; $y++) {
        if ($new->[$x][$y] == 0) {
          $issb = undef if $block;
        } else {
          $block = 1;
        }
        last unless $issb;
      }
      last unless $issb;
    }
  } elsif ($sbgiven eq 'q') {
  } elsif ($sbgiven eq 'o') {
    for (my $y=0; $y<FIELD_HEIGHT; $y++) {
      for (my $x=0; $x<FIELD_WIDTH; $x++) {
        $issb = undef if $new->[$x][$y] == 14;
        last unless $issb;
      }
      last unless $issb;
    }
  } else {
    Report('debug', undef, $s, "DEBUG: Unknown sbgiven value ($sbgiven)");
  }

  if ($issb) {
    $Users{$s}{gs}{prev}{sbgiven} = $sbgiven;
  } else {
    unshift(@{$Users{$s}{gs}{sbgiven}}, $sbgiven);
  }

  return $issb;
}

sub GameStatsOnSb {
  my ($s, $to, $sb, $from) = @_;
  my $ch = $Users{$s}{channel};

  if ($sb =~ /^cs(\d+)$/) {
  # classic style add_line_to_all
    my $num = $1;
    $Users{$s}{gs}{gamestate} = 2;
    if ($num == 1) {
      $Users{$s}{gs}{lines} += 2;
    } elsif ($num == 2) {
      $Users{$s}{gs}{lines} += 3;
    } elsif ($num >= 4) { # clearing 5 or more lines possible occurs
      $Users{$s}{gs}{lines} += $num;
    }
    my $added = ($num < 4 ? $num : 4); # 4 lines will be added even if 5 lines are cleared
    $Users{$s}{gs}{csadded} += $added;
    $Users{$s}{gs}{tetris}++ if $num == 4;
  } else {
    $Users{$s}{gs}{specials}++;
  }

  if ($to == $from) {
    $Users{$s}{gs}{pieces} -= $Users{$s}{gs}{prev}{pieces};
    $Users{$s}{gs}{lines} -= $Users{$s}{gs}{prev}{lines};
    my $sbgiven = $Users{$s}{gs}{prev}{sbgiven};
    unshift(@{$Users{$s}{gs}{sbgiven}}, $sbgiven) if $sbgiven ne '';
    $Users{$s}{gs}{prev} = {InitialGameStatsPrev()};

    $Users{$s}{gs}{gamestate} = 3;
  }

  return if $ch->{game}{gametype} == 2;

  if ($to == 0) {
    for (my $i=1; $i<=MAXPLAYERS; $i++) {
      my $user = $ch->{players}[$i] or next;
      next if $i == $from;
      next if not $Users{$user}{alive};
      push(@{$Users{$user}{gs}{sbgiven}}, $sb);
    }
  } elsif ($to == $from) {
  } else {
    my $user = $ch->{players}[$to];
    push(@{$Users{$user}{gs}{sbgiven}}, $sb) if (defined $user and $Users{$user}{alive});
  }
}

sub BlockFrequency {
  my ($ch) = @_;
  my $blocks = ('3' x $ch->{blockleftl}) . ('5' x $ch->{blockleftz}) . ('2' x  $ch->{blocksquare}) .
               ('4' x  $ch->{blockrightl}) . ('6' x  $ch->{blockrightz}) . ('7' x  $ch->{blockhalfcross}) . ('1' x  $ch->{blockline});
  my $specials = ('1' x $ch->{specialaddline}) . ('2' x $ch->{specialclearline}) . ('3' x $ch->{specialnukefield}) .
                 ('4' x $ch->{specialrandomclear}) . ('5' x $ch->{specialswitchfield}) . ('6' x $ch->{specialclearspecial}) .
                 ('7' x $ch->{specialgravity}) . ('8' x $ch->{specialquakefield}) . ('9' x $ch->{specialblockbomb});
  return ($blocks, $specials);
}

sub IsPure {
  my ($ch) = @_;
  return ($ch->{specialadded} == 0 or $ch->{specialcapacity} == 0);
}

sub PlayedGame {
  my ($s) = @_;
  return undef if ($Users{$s}{gs}{lines} <= 0 and $Users{$s}{gs}{csadded} <= 0 and
                   $Users{$s}{gs}{specials} <= 0);
  return 1;
}

sub GameTime {
  my ($ch) = @_;
  return TimeInterval($ch->{game}{timestart}, ($ch->{game}{timeend} or RealTime()));
}

sub ResetGameTime {
  my ($ch) = @_;
  $ch->{game}{timestart} = RealTime();
  $ch->{game}{timeend} = undef;
}

sub SetGameTimeEnd {
  my ($ch) = @_;
  $ch->{game}{timeend} = RealTime();
}

sub PauseGameTime {
  my ($ch) = @_;

  my $a = $ch->{game}{timestart};
  my $b = RealTime();
  my $time = (${$a}[0] - ${$b}[0]) + ((${$a}[1] - ${$b}[1]) / 1_000_000); # see also: TimeInterval()

  my $sec = int $time;
  my $msec = int(($time - $sec) * 1_000_000);
  $ch->{game}{timestart} = [abs $sec, abs $msec];
}

sub UnpauseGameTime {
  my ($ch) = @_;

  my $a = $ch->{game}{timestart};
  my $b = RealTime();
  # $a is positive value, but $a should be treat as 0 or less value
  my $time = (${$b}[0] - ${$a}[0]) + ((${$b}[1] - ${$a}[1]) / 1_000_000); # see also: TimeInterval()

  my $sec = int $time;
  my $msec = int(($time - $sec) * 1_000_000);
  $ch->{game}{timestart} = [abs $sec, abs $msec];
}

# =================================================================
#     Game Field functions
# =================================================================

sub EmptyField {
  my $field;
  for (my $y=0; $y<FIELD_HEIGHT; $y++) {
    for (my $x=0; $x<FIELD_WIDTH; $x++) {
      $field->[$x][$y] = 0; # 0 is blank
    }
  }
  return $field;
}

sub UpdateField {
  my ($old, $update) = @_;

  # makes clone to keep old field data
  my $field = EmptyField();
  for (my $y=0; $y<FIELD_HEIGHT; $y++) {
    for (my $x=0; $x<FIELD_WIDTH; $x++) {
      $field->[$x][$y] = $old->[$x][$y];
    }
  }

  return $field if $update eq '';

  if ( 0x21 <= ord($update) and ord($update) <= 0x2F ) {
  # changed blocks data is sent
    my $indicator = undef;
    for (my $i=0; $i<length($update); $i++) {
      my $code = ord(substr($update, $i, 1));
      if ( 0x21 <= $code and $code <= 0x2F ) {
      # $code is a block type indicator
        $indicator = $code - 0x21;
      } else {
      # $code and the next character are location(x, y coordinate)
        my $nextcode = ord(substr($update, $i+1, 1));
        return undef unless (defined $indicator and 0x33 <= $code and $code <= 0x3E and
                                                    0x33 <= $nextcode and $nextcode <= 0x48);
        $field->[$code - 0x33][$nextcode - 0x33] = $indicator;
        $i++;
      }
    }
  } else {
  # all blocks data is sent
    return undef if (length($update) != FIELD_HEIGHT * FIELD_WIDTH);
    for (my $i=0; $i<length($update); $i++) {
      $field->[$i%FIELD_WIDTH][int $i/FIELD_WIDTH] = ascii2inexp(substr($update, $i, 1));
    }
  }

  return $field;
}

sub all_field_blocks {
  my ($field) = @_;

  my $all = '';
  for (my $y=0; $y<FIELD_HEIGHT; $y++) {
    for (my $x=0; $x<FIELD_WIDTH; $x++) {
      $all .= inexp2ascii($field->[$x][$y]);
    }
  }
  return $all;
}

sub ascii2inexp {
  my ($ascii) = @_;
  for (my $i=0; $i<@{(BLOCKS)}; $i++) {
    return $i if BLOCKS->[$i] eq $ascii;
  }
  return undef;
}

sub inexp2ascii {
  my ($inexp) = @_;
  return BLOCKS->[$inexp];
}

# =================================================================
#     Sudden Death functions
# =================================================================

sub SetSuddenDeath {
  my ($ch) = @_;
  return unless $ch->{game}{sdtimeout} > 0;

  my $next = PTime() + $ch->{game}{sdtimeout};
  $ch->{sd} = {next => $next, timedout => undef};
}

sub CheckSuddenDeath {
  my ($ch) = @_;
  return unless defined $ch->{sd};
  return unless ($ch->{ingame} and not $ch->{paused});

  my $time = PTime();
  my $sd = $ch->{sd};
  return unless $sd->{next} <= $time;
  if ($sd->{timedout}) {
    for (my $i=0; $i<$ch->{game}{sdlinesperadd}; $i++) {
      for (my $i=1; $i<=MAXPLAYERS; $i++) {
        my $user = $ch->{players}[$i] or next;
        next unless $Users{$user}{alive};
        Send($user, 'sb', 0, 'a', 0);
        push(@{$Users{$user}{gs}{sbgiven}}, 'a');
      }
    }
    $sd->{next} = $time + $ch->{game}{sdsecsbetweenlines};
  } else {
    SendToChannel($ch, 0, 'gmsg', [$ch->{game}{sdmessage}]) if $ch->{game}{sdmessage} ne '';
    $sd->{timedout} = 1;
    $sd->{next} = $time + $ch->{game}{sdsecsbetweenlines};
  }
}

sub PauseSuddenDeath {
  my ($ch) = @_;
  $ch->{sd}{next} -= PTime() if defined $ch->{sd};
}

sub UnpauseSuddenDeath {
  my ($ch) = @_;
  $ch->{sd}{next} += PTime() if defined $ch->{sd};
}

sub RemoveSuddenDeath {
  my ($ch) = @_;
  $ch->{sd} = undef;
}

# =================================================================
#     Starting count functions
# =================================================================

sub SetStartingCount {
  my ($ch, $count) = @_;
  my $next = PTime() + STARTINGCOUNTINTERVAL;
  $ch->{sc} = {next => $next, count => $count};
}

sub IsSetStartingCount {
  my ($ch) = @_;
  return (defined $ch->{sc} ? 1 : undef);
}

sub CheckStartingCount {
  my ($ch) = @_;
  return unless defined $ch->{sc};
  return if $ch->{ingame};

  my $time = PTime();
  my $sc = $ch->{sc};
  return unless $sc->{next} <= $time;
  if ($sc->{count} > 0) {
    SendToChannel($ch, 0, 'pline', 0, [$sc->{count}]);
    $sc->{count}--;
    $sc->{next} = $time + STARTINGCOUNTINTERVAL;
  } else {
    StartGame($ch);
  }
}

sub RemoveStartingCount {
  my ($ch) = @_;
  $ch->{sc} = undef;
}

# =================================================================
#     Channel/Nick functions
# =================================================================

sub UpdateChannels {
  my @chsecs = (); # channel sections
  foreach my $section ( $Config->Sections() ) {
    push(@chsecs, $1) if $section =~ /^Channel(\d+)$/;
  }

  foreach my $no ( sort {$a <=> $b} @chsecs ) {
    my $section = "Channel$no";
    next if $Config->val($section, 'Name') eq '';

    my $ch;
    my $new = undef;
    unless ( $ch = TargetChannel(CHANNELPREFIX . $Config->val($section, 'Name')) ) {
      $ch = {InitialChannelData(), persistant => 1};
      $new = 1;
    }

    foreach my $key ( $Config->Parameters($section) ) {
      $ch->{lc $key} = $Config->val($section, $key);
    }
    NormalizeChannelConfig($ch);
    push(@Channels, $ch) if $new;
  }
}

sub JoinChannel {
  my ($s, $ch, $justconnected) = @_;
  my $slot = OpenSlot($ch) or return;

  LeaveChannel($s, $ch);

  Send($s, 'winlist', Winlist($ch));

  SendPlayernum($s, $slot);
  $Users{$s}{playernum}[0]{sendplayerjoin} = 1;
  $Users{$s}{playernum}[0]{justconnected} = 1 if $justconnected;
  $ch->{players}[$slot] = undef;
  $ch->{reserved}[$slot] = $s;
  $Users{$s}{channel} = $ch;
  $Users{$s}{slot} = $slot;
  $Users{$s}{alive} = undef;
  $Users{$s}{field} = EmptyField();

  SendChannelInfo($s, 0) if not $justconnected;
}

sub SendChannelInfo {
  my ($s, $justconnected) = @_;

  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    next if $i == $slot;
    Send($s, 'playerjoin', $i, $Users{$user}{nick});
    Send($s, 'team', $i, $Users{$user}{team});
  }

  # send `f' after all `playerjoin' and `team' messages have been sent
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    next if $i == $slot;
    Send($s, 'playerlost', $i) if ($ch->{ingame} and not $Users{$user}{alive});
    Send($s, 'f', $i, all_field_blocks($Users{$user}{field}));
  }

  SendFromFile($s, 'motd') if $justconnected;

  Send($s, 'ingame') if $ch->{ingame};
  Send($s, 'pause', ($ch->{paused} ? 1 : 0));
  Send($s, 'playerlost', $slot) if $ch->{ingame};

  Send($s, 'pline', 0, [Msg('HasJoinedChannelIn', $Users{$s}{nick}, ChannelName($ch))]) if $justconnected;
  SendFromFile($s, lc $ch->{welcomemessage}) if $ch->{welcomemessage} ne '';

  ShowLmsg($s) if $justconnected;
}

sub LeaveChannel {
  my ($s, $jointo) = @_;
  return unless defined $Users{$s}{channel};

  my $ch = $Users{$s}{channel};
  my $slot = $Users{$s}{slot};

  my $reserved = (defined $ch->{reserved}[$slot]);
  $ch->{players}[$slot] = undef;
  $ch->{reserved}[$slot] = undef;

  if ($ch->{ingame}) {
    OnPlayerlost($s, "playerlost $slot");
    Send($s, 'endgame') if defined $jointo;
  }

  if (not $reserved) {
    SendToChannel($ch, $slot, 'pline', 0, [Msg('HasJoinedChannelOut', $Users{$s}{nick}, ChannelName($jointo))]) if defined $jointo;
    SendToChannel($ch, $slot, 'playerleave', $slot);
  }

  if (defined $jointo) { # if not close connection
    Send($s, 'playerleave', $slot);
    for (my $i=1; $i<=MAXPLAYERS; $i++) {
      my $user = $ch->{players}[$i] or next;
      Send($s, 'playerleave', $i);
    }
  }
}

sub CompactPlayers {
  my ($ch) = @_;
  return if NumberReserved($ch) > 0;

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    next if defined $ch->{players}[$i];
    for (my $j=$i+1; $j<=MAXPLAYERS; $j++) {
      next unless defined $ch->{players}[$j];
      my $user = $ch->{players}[$j];
      $Users{$user}{slot} = $i;
      $ch->{players}[$i] = $user;
      $ch->{players}[$j] = undef;
      SendPlayernum($user, $i);
      $Users{$user}{field} = EmptyField();
      SendToChannel($ch, $i, 'playerjoin', $i, $Users{$user}{nick});
      SendToChannel($ch, $i, 'team', $i, $Users{$user}{team});
      SendToChannel($ch, 0, 'playerleave', $j);
      last;
    }
  }
}

sub ShufflePlayers {
  my ($ch) = @_;
  return if NumberReserved($ch) > 0;

  my @old = @{$ch->{players}};
  $ch->{players} = [];
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    next unless defined $old[$i];
    my $user = $old[$i];
    splice(@{$ch->{players}}, int rand(@{$ch->{players}}+1), 0, $user);
  }
  unshift(@{$ch->{players}}, undef);
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    next if $ch->{players}[$i] eq $old[$i];
    if (defined $ch->{players}[$i]) {
      my $user = $ch->{players}[$i];
      $Users{$user}{slot} = $i;
      SendPlayernum($user, $i);
      $Users{$user}{field} = EmptyField();
    } else {
      $ch->{players}[$i] = undef;
    }
  }
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    next if $ch->{players}[$i] eq $old[$i];
    if (defined $ch->{players}[$i]) {
      my $user = $ch->{players}[$i];
      SendToChannel($ch, $i, 'playerjoin', $i, $Users{$user}{nick});
      SendToChannel($ch, $i, 'team', $i, $Users{$user}{team});
    } else {
      SendToChannel($ch, 0, 'playerleave', $i);
    }
  }
}

# return the number of players on given channel
sub NumberPlayers {
  my ($ch) = @_;
  my $plsnum = 0;
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    $plsnum++ if (defined $ch->{players}[$i] or defined $ch->{reserved}[$i]);
  }
  return $plsnum;
}

# return the number of reserved players on given channel
sub NumberReserved {
  my ($ch) = @_;
  my $plsnum = 0;
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    $plsnum++ if defined $ch->{reserved}[$i];
  }
  return $plsnum;
}

# find the least open number channel of the highest priority ones
sub OpenChannel {
  my @max = (undef, 0);
  foreach my $ch (@Channels) {
    @max = ($ch, $ch->{priority}) # if it has Higher Priority and does not have Full Players
        if ($max[1] < $ch->{priority} and ($ch->{maxplayers} - NumberPlayers($ch)) > 0);
  }
  return $max[0];
}

# return the least number of open slot on given channel
sub OpenSlot {
  my ($ch) = @_;
  return undef unless ($ch->{maxplayers} - NumberPlayers($ch) > 0);

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    return $i if (not defined $ch->{players}[$i] and not defined $ch->{reserved}[$i]);
  }
  return undef;
}

# return moderator number on given channel
sub ModeratorSlot {
  my ($ch) = @_;
  return 0 unless defined $ch;

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    return $i if defined $ch->{players}[$i];
  }
  return 0;
}

sub ChannelName {
  my ($ch) = @_;
  return '' unless defined $ch;

  my $chname = CHANNELPREFIX . $ch->{name};
  return $chname;
}

# return channel number (index of the @Channels) of given channel
sub ChannelNo {
  my ($ch) = @_;
  return undef unless defined $ch;

  for (my $i=0; $i<@Channels; $i++) {
    return $i if $Channels[$i] eq $ch;
  }
  return undef;
}

sub TargetChannel {
  my ($target) = @_;
  return (wantarray ? (undef, '') : undef) if (not defined $target or $target eq '');

  my $ch = undef;
  my $chname = '';
  if ( substr($target, 0, length(CHANNELPREFIX)) eq CHANNELPREFIX ) {
    $chname = substr($target, length(CHANNELPREFIX), MAXCHANNELLENGTH);
    for (my $i=0; $i<@Channels; $i++) {
      ($ch = $Channels[$i], last) if (lc $Channels[$i]{name} eq lc $chname);
    }
  } else {
    my $chno = ($target =~ /^(\d+)/ ? $1 : 0) - 1;
    $ch = $Channels[$chno] if ( 0 <= $chno and $chno <= @Channels-1 );
  }

  return wantarray ? ($ch, $chname) : $ch ;
}

sub SendToChannel {
  my ($ch, $opt, @msg) = @_;
  return unless defined $ch;

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    next if $i == $opt; # send to channel members but $opt slot (0 for all)
    Send($user, @msg);
  }
}

# delete no persistant channel that no one is on
sub GarbageChannel {
  my ($ch) = @_;
  return unless defined $ch;
  return unless not $ch->{persistant};
  return unless NumberPlayers($ch) == 0;

  my $i = ChannelNo($ch);
  RemoveSuddenDeath($ch);
  splice(@Channels, $i, 1);
}

sub NormalizeChannelConfig {
  my ($ch) = @_;

  $ch->{name} = StripColors($ch->{name});
  $ch->{name} = substr($ch->{name}, 0, MAXCHANNELLENGTH) if length($ch->{name}) > MAXCHANNELLENGTH;
  $ch->{name} =~ s/\s/_/g;
  $ch->{maxplayers} = ToInt($ch->{maxplayers}, 1, MAXPLAYERS);
  $ch->{priority} = ToInt($ch->{priority}, 0, 99);
  $ch->{announcerank} = ToInt($ch->{announcerank}, 0, MAXPLAYERS);
  $ch->{gamestatsmsg} = ToInt($ch->{gamestatsmsg}, 0, undef);
  $ch->{gametype} = ToInt($ch->{gametype}, 1, 2);
  $ch->{topic} =~ s/^\s+//; $ch->{topic} =~ s/\s+$//;
  $ch->{topic} = '' if $ch->{topic} eq '-';
  $ch->{topic} = substr($ch->{topic}, 0, MAXTOPICLENGTH);

  my @stack = split(/\s+/, $ch->{stack});
  for (my $i=0; $i<MAXPLAYERS; $i++) {
    $stack[$i] = ToInt($stack[$i], 0, FIELD_HEIGHT);
  }
  $ch->{stack} = join(' ', @stack);

  $ch->{startinglevel} = ToInt($ch->{startinglevel}, 1, 100);
  $ch->{linesperlevel} = ToInt($ch->{linesperlevel}, 1, 100);
  $ch->{levelincrease} = ToInt($ch->{levelincrease}, 0, 100);
  $ch->{linesperspecial} = ToInt($ch->{linesperspecial}, 1, 100);
  $ch->{specialadded} = ToInt($ch->{specialadded}, 0, 100);
  $ch->{specialcapacity} = ToInt($ch->{specialcapacity}, 0, 18);
  $ch->{classicrules} = ($ch->{classicrules} ? 1 : 0);
  $ch->{averagelevels} = ($ch->{averagelevels} ? 1 : 0);

  $ch->{sdtimeout} = ToInt($ch->{sdtimeout}, 0, 600);
  $ch->{sdlinesperadd} = ToInt($ch->{sdlinesperadd}, 0, FIELD_HEIGHT);
  $ch->{sdsecsbetweenlines} = ToInt($ch->{sdsecsbetweenlines}, 1, 300);
  $ch->{sdmessage} =~ s/^\s+//; $ch->{sdmessage} =~ s/\s+$//;
  $ch->{sdmessage} = '' if $ch->{sdmessage} eq '-';
  $ch->{sdmessage} = substr($ch->{sdmessage}, 0, MAXSDMSGLENGTH) if length($ch->{sdmessage}) > MAXSDMSGLENGTH;

  $ch->{blockleftl} = ToInt($ch->{blockleftl}, 0, 100);
  $ch->{blockleftz} = ToInt($ch->{blockleftz}, 0, 100);
  $ch->{blocksquare} = ToInt($ch->{blocksquare}, 0, 100);
  $ch->{blockrightl} = ToInt($ch->{blockrightl}, 0, 100);
  $ch->{blockrightz} = ToInt($ch->{blockrightz}, 0, 100);
  $ch->{blockhalfcross} = ToInt($ch->{blockhalfcross}, 0, 100);
  $ch->{blockline} = ToInt($ch->{blockline}, 0, 100);

  $ch->{specialaddline} = ToInt($ch->{specialaddline}, 0, 100);
  $ch->{specialclearline} = ToInt($ch->{specialclearline}, 0, 100);
  $ch->{specialnukefield} = ToInt($ch->{specialnukefield}, 0, 100);
  $ch->{specialrandomclear} = ToInt($ch->{specialrandomclear}, 0, 100);
  $ch->{specialswitchfield} = ToInt($ch->{specialswitchfield}, 0, 100);
  $ch->{specialclearspecial} = ToInt($ch->{specialclearspecial}, 0, 100);
  $ch->{specialgravity} = ToInt($ch->{specialgravity}, 0, 100);
  $ch->{specialquakefield} = ToInt($ch->{specialquakefield}, 0, 100);
  $ch->{specialblockbomb} = ToInt($ch->{specialblockbomb}, 0, 100);
}

sub TargetNick {
  my ($target) = @_;
  return undef if (not defined $target or $target eq '');

  $target = StripColors(lc $target);
  foreach my $player (values %Users) {
    next unless (defined $player and $player->{nick} ne '');
    my $nick = StripColors(lc $player->{nick});
    return $player->{socket} if $target eq $nick;
  }

  return undef;
}

sub PingLatest {
  my ($s) = @_;
  return '-' unless defined $Users{$s};

  return '-' unless defined $Users{$s}{ping}[0];
  return round($Users{$s}{ping}[0], SCOREDECIMAL);
}

sub PingAve {
  my ($s) = @_;
  return '-' unless defined $Users{$s};

  my $items = scalar @{$Users{$s}{ping}};
  return '-' if $items == 0;

  my $sum = 0;
  foreach (@{$Users{$s}{ping}}) {
    $sum += $_;
  }
  my $ave = $sum / $items;

  return round($ave, SCOREDECIMAL);
}

# =================================================================
#     Checking (certify/verify) clients function
# =================================================================

sub IsCheckingClient {
  my ($s) = @_;

  return ( IsCertifyingClient($s) or IsVerifyingClient($s) );
}

sub EndCheckingClient {
  my ($s) = @_;

  my $slot = $Users{$s}{slot};
  my $team = $Users{$s}{team};
  OnTeam($s, "team $slot $team");
}

sub IsCertifyingClient {
  my ($s) = @_;

  return ($Users{$s}{checking}[0] ? 1 : undef);
}

sub StartCertifyClient {
  my ($s) = @_;

  $Users{$s}{checking}[0] = 1;
  Send($s, 'pline', 0, [Msg('RegisteredNickEnterPassword')]);
}

sub EndCertifyClient {
  my ($s) = @_;

  $Users{$s}{checking}[0] = undef;
  Send($s, 'pline', 0, [Msg('Certified')]);

  # if VerifyClient is set to 1, player is not required to verify his client
  if ( $Config->val('Main', 'VerifyClient') == 1 ) {
    EndGameOnVerify($s) if IsVerifyingClient($s);
  }

  EndCheckingClient($s) unless IsCheckingClient($s);
}

sub IsVerifyingClient {
  my ($s) = @_;

  return ($Users{$s}{checking}[1] ? 1 : undef);
}

sub StartVerifyClient {
  my ($s) = @_;

  $Users{$s}{checking}[1] = 1;
  $Users{$s}{verified} = []; # initialize verifying data

  # send newgame
  my $stack = 0;
  my $startinglevel = 100;
  my $linesperlevel = 1;
  my $levelincrease = 5;
  my $linesperspecial = 1;
  my $specialadded = 1;
  my $specialcapacity = 0;
  my $blocks = '2' x 100; # `2' is square
  my $specials = '4' x 100; # `4' is random clear
  my $averagelevels = 1;
  my $classicrules = 1;

  Send($s, Newgame($s), $stack,
      $startinglevel, $linesperlevel, $levelincrease,
      $linesperspecial, $specialadded, $specialcapacity,
      $blocks, $specials,
      $averagelevels, $classicrules
  );

  # send field
  my $slot = $Users{$s}{slot};
  my $field = "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000" .
              "000010010000" .
              "000000000000";
  Send($s, 'f', $slot, $field);

  # send all verifying messages
  for (my $i=0; ; $i++) {
    last if Msg($s, "Verifying$i") eq '';
    Send($s, 'pline', 0, [Msg("Verifying$i")]);
  }
  for (my $i=0; ; $i++) {
    last if Msg($s, "VerifyingGmsg$i") eq '';
    Send($s, 'gmsg', [Msg("VerifyingGmsg$i")]);
  }
}

sub EndVerifyClient {
  my ($s) = @_;

  EndGameOnVerify($s);

  $Users{$s}{verified} = 1;
  Send($s, 'pline', 0, [Msg('Verified')]);

  EndCheckingClient($s) unless IsCheckingClient($s);
}

sub EndGameOnVerify {
  my ($s) = @_;

  $Users{$s}{checking}[1] = undef;
  $Users{$s}{verified} = undef;
  Send($s, 'endgame');
}

# =================================================================
#     Profile functions
# =================================================================

sub ReadProfile {
  my ($default) = @_;
  my $file = PROFILEFILE;

  if ( open(IN, "< $file") ) {
    @Profiles = ();
    while (my $line = <IN>) {
      $line =~ tr/\x0D\x0A//d; # strip crlf
      my ($type, $name, @args) = split(/ /, $line);
      $name = StripColors($name);
      $Profiles[$type] = {} if not defined $Profiles[$type];
      $Profiles[$type]{lc $name} = [$name, @args];
    }
    close(IN);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open profile file `$file' to read");
    return undef unless $default;
    @Profiles = ();
  }

  for (my $i=0; $i<@Profiles; $i++) {
    next unless defined $Profiles[$i];
    foreach my $profile (values %{$Profiles[$i]}) {
      if ($i == 0) {
        splice(@$profile, PF_PLOCALE, 0, '') if (scalar @$profile == 9); # -v0.17 to v0.18
        NormalizePlayerProfileData($profile);
      }
    }
  }

  return 1;
}

sub WriteProfile {
  my $file = PROFILEFILE;

  if ( open(OUT, "> $file") ) {
    for (my $i=0; $i<@Profiles; $i++) {
      next unless defined $Profiles[$i];
      foreach my $profile (values %{$Profiles[$i]}) {
        my $data = join(' ', @$profile);
        print OUT "$i $data\n";
      }
    }
    close(OUT);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open profile file `$file' to write");
  }
}

sub GetPlayerProfile {
  my ($nick, $maxstacklevel) = @_;
  $Misc{stacklevel}++;

  my $name = StripColors($nick);
  if (defined $Profiles[PF_P]{lc $name}) {
    if ($Misc{stacklevel} <= $maxstacklevel) {
      my $alias = $Profiles[PF_P]{lc $name}[PF_PALIAS];
      return GetPlayerProfile($alias, $maxstacklevel) if $alias ne '';
    }
  } else {
    $Profiles[PF_P]{lc $name} = [InitialPlayerProfileData($name)];
    NormalizePlayerProfileData($Profiles[PF_P]{lc $name});
  }
  $Misc{stacklevel} = 0;
  return $Profiles[PF_P]{lc $name};
}

sub DefinedPlayerProfile {
  my ($nick) = @_;

  my $name = StripColors($nick);
  return (defined $Profiles[PF_P]{lc $name});
}

sub InitialPlayerProfileData {
  my ($name) = @_;
  my $alias = '';
  my $password = '';
  my $authority = $Config->val('Authority', 'User');
  my $team = '';
  my $locale = '';
  my $logins = 0;
  my $lastlogin = 0;
  my $onlinetime = 0;
  my $games = 0;
  return ($name, $alias, $password, $authority, $team, $locale, $logins, $lastlogin, $onlinetime, $games);
}

sub NormalizePlayerProfileData {
  my ($pf) = @_;

  $pf->[PF_PNAME] = StripColors($pf->[PF_PNAME]);
  $pf->[PF_PAUTHORITY] = ToInt($pf->[PF_PAUTHORITY], 0, undef);
  $pf->[PF_PLOGINS] = ToInt($pf->[PF_PLOGINS], 0, undef);
  $pf->[PF_PLASTLOGIN] = ToInt($pf->[PF_PLASTLOGIN], 0, undef);
  $pf->[PF_PONLINETIME] = ToInt($pf->[PF_PONLINETIME], 0, undef);
  $pf->[PF_PGAMES] = ToInt($pf->[PF_PGAMES], 0, undef);
}

# =================================================================
#     Winlist functions
# =================================================================

# read winlist from files
sub ReadWinlist {
  @Winlist = ();

  my @wlsecs = (); # winlist sections
  foreach my $section ( $Config->Sections() ) {
    push(@wlsecs, $1) if $section =~ /^Winlist(\d+)$/;
  }

  foreach my $wlno ( sort {$a <=> $b} @wlsecs ) {
    my $section = "Winlist$wlno";
    my $file = $Config->val($section, 'File');
    next if $file eq '';
    my %data = (
      file => $file,
      playeronly => ToInt($Config->val($section, 'PlayerOnly'), 0, 1),
      type => ToInt($Config->val($section, 'Type'), 1, 4),
    );
    my $wl = [\%data, [], [], [], []];
    $Winlist[$wlno] = $wl;

    if ( open(IN, "< $file") ) {
      while (my $line = <IN>) {
        if ($line =~ /^\d/) { # new format (v0.10 or later)
          next unless $line =~ /^(\d+) ([^ ]+) ([0-9.]+)$/;
          push(@{$wl->[$1]}, [StripColors($2), $3]) if $1 >= 1;
        } else { # old format
          next unless $line =~ /^([^ ]+) ([0-9.]+)$/;
          push(@{$wl->[1]}, [StripColors($1), $2]);
        }
      }
      close(IN);
    } else {
      Report('error', undef, undef, "ERROR: Cannot open winlist file `$file' to read");
    }
  }
}

# write out winlist to files
sub WriteWinlist {
  foreach my $wl (@Winlist) {
    next unless defined $wl;
    my $file = $wl->[0]{file};
    if ( open(OUT, "> $file") ) {
      for (my $i=1; $i<@$wl; $i++) {
        foreach (@{$wl->[$i]}) {
          my ($name, $value) = @$_;
          print OUT "$i $name $value\n";
        }
      }
      close(OUT);
    } else {
      Report('error', undef, undef, "ERROR: Cannot open winlist file `$file' to write");
    }
  }
}

sub ResetWinlistAll {
  my ($backup) = @_;

  my $resall = undef;
  my @files = ();
  for (my $i=0; $i<@Winlist; $i++) {
    my ($result, $file) = ResetWinlist($i, $backup);
    if ($result) {
      push(@files, $file);
      $resall = 1;
    }
  }

  return wantarray ? ($resall, @files) : $resall;
}

sub ResetWinlist {
  my ($no, $backup) = @_;
  return undef unless ($no >= 0 and defined $Winlist[$no]);

  WriteWinlist();
  my $wl = $Winlist[$no];
  my $file = $wl->[0]{file};
  (rename($file, $file . BACKUPSUFFIX) or return undef) if $backup;

  for (my $i=1; $i<@$wl; $i++) {
    $wl->[$i] = [];
  }

  return wantarray ? (1, $wl->[0]{file}) : 1;
}

sub SendWinlistList {
  my ($s) = @_;
  for (my $i=0; $i<@Winlist; $i++) {
    my $wl = $Winlist[$i];
    next unless defined $wl;
    my $file = $wl->[0]{file};
    Send($s, 'pline', 0, [Msg('ListWinlist', $i, $file)]);
  }
}

# return winlist data for `winlist' message
sub Winlist {
  my ($ch) = @_;

  my $wl = WinlistData($ch) or return '';
  my $wltype = $wl->[0]{type};
  my $msg = '';
  for (my $i=0; $i<10; $i++) {
    last unless defined $wl->[$wltype][$i];
    my ($name, $value) = @{$wl->[$wltype][$i]};
    $name =~ tr/;/:/;
    $value = ToInt($value, undef, undef);
    $msg .= "$name;$value ";
  }
  $msg =~ s/ $//;

  return $msg;
}

sub WinlistData {
  my ($ch) = @_;

  my $wlno = $ch->{winlist};
  return undef unless ($wlno >= 0 and defined $Winlist[$wlno]);
  return $Winlist[$wlno];
}

# return score of given player/team or number(rank-1)
sub Score {
  my ($wl, $no, $target) = @_;
  return undef unless defined $wl;

  my $wltype = $wl->[0]{type};
  if (defined $no) {
    $no = ToInt($no, 0, undef);
    return undef unless defined $wl->[$wltype][$no];
    my ($name, $value) = @{$wl->[$wltype][$no]};
    return ($no, $name, $value);
  } else {
    $target = StripColors(lc $target);
    for (my $i=0; $i<@{$wl->[$wltype]}; $i++) {
      next unless defined $wl->[$wltype][$i];
      my ($name, $value) = @{$wl->[$wltype][$i]};
      next unless lc($name) eq $target;
      return ($i, $name, $value);
    }
    return undef;
  }
}

sub WinlistCalculate {
  my ($ch) = @_;

  my @players = @{$ch->{game}{players}};

  my %teams = (); # teams at start
  foreach my $plinfo (@players) {
    my $name = $plinfo->{name};
    my $lcname = lc $name;
    $teams{$lcname} = [] if not defined $teams{$lcname};
    push(@{$teams{$lcname}}, $plinfo);
  }

  my @rank = ();

  my $gametype = $ch->{game}{gametype};
  if ($gametype == 1) { # normal
    my %tmp = ();
    foreach my $plinfo (@players) {
      my $lcname = lc $plinfo->{name};
      next if defined $tmp{$lcname};
      push(@rank, [ @{$teams{$lcname}} ]);
      $tmp{$lcname} = 1;
    }
  } elsif ($gametype == 2) { # self survival
    $rank[0] = [];
    foreach my $plinfo (@players) {
      push(@{$rank[0]}, $plinfo);
    }
  } else {
    Report('error', undef, undef, "ERROR: Invalid gametype value ($gametype)");
    return (undef, undef);
  }

  my $wl = WinlistData($ch) or return (\@rank, undef);
  my $wltype = $wl->[0]{type};
  if ($wltype == 1) { # adding points
    # one-team (one-player) or self-survival games have no points
    return (\@rank, undef) unless scalar(@rank) > 1;

    my $winners = scalar @{$rank[0]}; # the number of winner players
    my $starters = scalar @{$ch->{game}{start}}; # the number of started players
    my $points = round(($starters / $winners) * 0.5, SCOREDECIMAL);

    my @names = ();
    if ( $wl->[0]{playeronly} ) {
      foreach my $plinfo ( @{$rank[0]} ) {
        my $nick = $plinfo->{nick};
        push(@names, [$wltype, "p$nick", $points]);
      }
    } else {
      my $name = $rank[0][0]{name};
      push(@names, [$wltype, $name, $points]);
    }

    my $score = WinlistAdd($wl, \@names, 0, 0);
    return (\@rank, $score);
  } elsif ($wltype == 2) { # number of cleared lines
    # self-survival game only
    return (\@rank, undef) unless $gametype == 2;

    my @names = ();
    foreach my $plinfo ( @{$rank[0]} ) {
      my $name = ($wl->[0]{playeronly} ? 'p' . $plinfo->{nick} : $plinfo->{name});
      my $lines = $plinfo->{lines};
      push(@names, [$wltype, $name, $lines]);
    }

    my $score = WinlistAdd($wl, \@names, 1, 0);
    return (\@rank, $score);
  } elsif ($wltype == 3 or $wltype == 4) { # highest/lowest lifetime seconds
    # self-survival game only
    return (\@rank, undef) unless $gametype == 2;

    my @names = ();
    foreach my $plinfo ( @{$rank[0]} ) {
      my $name = ($wl->[0]{playeronly} ? 'p' . $plinfo->{nick} : $plinfo->{name});
      my $lifetime = $plinfo->{lifetime};
      push(@names, [$wltype, $name, $lifetime]);
    }

    my $replace = ($wltype == 4 ? 2 : 1);
    my $score = WinlistAdd($wl, \@names, $replace);
    return (\@rank, $score);
  } else {
    Report('error', undef, undef, "ERROR: Invalid wltype value ($wltype)");
    return (\@rank, undef);
  }

  return (undef, undef);
}

# $replace 0=add points 1=highest replace 2=lowest replace
sub WinlistAdd {
  my ($wl, $data, $replace) = @_;
  return undef unless defined $wl;

  my @result = ();
  foreach (@$data) {
    my ($wltype, $name, $value) = @$_;
    next unless $value > 0;
    my $list = $wl->[$wltype];
    $name = StripColors($name);
    my ($no, $wlname, $wlvalue) = Score($wl, undef, $name);
    my $oldvalue = (defined $wlvalue ? $wlvalue : 0);

    if (defined $no and defined $list->[$no]) {
      if ($replace == 1) {
        next if $value <= $wlvalue;
        $wlvalue = $value;
      } elsif ($replace == 2) {
        next if $value >= $wlvalue;
        $wlvalue = $value;
      } else {
        $wlvalue = $wlvalue + $value;
      }
      splice(@$list, $no, 1);
    } else {
      $no = scalar @$list;
      ($wlname, $wlvalue) = ($name, $value);
    }
    $wlvalue = round($wlvalue, SCOREDECIMAL);
    my $increase = round($wlvalue - $oldvalue, SCOREDECIMAL);

    my $ok = undef;
    for (my $i=$no; $i>=1; $i--) {
      if ($replace == 2) {
        next if ($wlvalue < $list->[$i-1][1]);
      } else {
        next if ($wlvalue > $list->[$i-1][1]);
      }
      splice(@$list, $i, 0, [$wlname, $wlvalue]);
      push(@result, [$wltype, $wlname, $wlvalue, $i+1, $increase]);
      $ok = 1;
      last;
    }
    if (not $ok) { # the player is on top of the winlist
      unshift(@$list, [$wlname, $wlvalue]);
      push(@result, [$wltype, $wlname, $wlvalue, 1, $increase]);
    }
  }

  return \@result;
}

# =================================================================
#     Left message functions
# =================================================================

sub ReadLmsg {
  my ($default) = @_;
  my $file = LMSGFILE;

  if ( open(IN, "< $file") ) {
    %Lmsg = ();
    while (my $line = <IN>) {
      $line =~ tr/\x0D\x0A//d; # strip crlf
      my ($to, $from, $time, $msg) = split(/ /, $line, 4);
      $to = StripColors($to);
      $from = StripColors($from);
      $msg =~ s/^\s+//; $msg =~ s/\s+$//;
      $msg = StripColors($msg);
      AddLmsg($to, $from, $time, $msg);
    }
    close(IN);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open lmsg file `$file' to read");
    return undef unless $default;
    %Lmsg = ();
  }

  return 1;
}

sub WriteLmsg {
  my $file = LMSGFILE;

  if ( open(OUT, "> $file") ) {
    foreach my $to (keys %Lmsg) {
      foreach my $lmsg ( @{$Lmsg{$to}} ) {
        my ($from, $time, $msg) = @$lmsg;
        print OUT "$to $from $time $msg\n";
      }
    }
    close(OUT);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open lmsg file `$file' to write");
  }
}

sub AddLmsg {
  my ($to, $from, $time, $msg) = @_;

  $Lmsg{$to} = [] if not defined $Lmsg{$to};
  push(@{$Lmsg{$to}}, [$from, $time, $msg]);
}

sub ShowLmsg {
  my ($s) = @_;

  my $to = 'p' . lc($Users{$s}{profile}[PF_PNAME]);
  return if (not defined $Lmsg{$to} or @{$Lmsg{$to}} == 0);

  Send($s, 'pline', 0, [Msg('ListingLmsg')]);
  foreach ( @{$Lmsg{$to}} ) {
    my ($from, $time, $msg) = @$_;
    my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime($time);
    my $date = "$mon/$mday $hour:$min";
    Send($s, 'pline', 0, [Msg('ListLmsg', $from, $date, $msg)]);
  }

  $Lmsg{$to} = [];
}

# =================================================================
#     Daily Stats functions
# =================================================================

sub ReadDaily {
  my ($default) = @_;
  my $file = DAILYFILE;

  my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime();
  $file =~ s/%y/$year/g;
  $file =~ s/%m/$mon/g;
  $file =~ s/%d/$mday/g;

  my $config = Config::IniFiles->new(-file => $file);
  if (not defined $config) {
    return undef unless $default;
    $config = Config::IniFiles->new();
  }

  my %init = ( # default settings
    Games => 0,
    HighestPlayers => 0,
    Logins => 0,
  );

  %Daily = ();
  my $sect = "$year$mon$mday";
  foreach my $key (keys %init) {
    my $param = $key;
    if ( defined $config->val($sect, $param) ) {
      $Daily{lc $param} = $config->val($sect, $param);
    } else {
      $Daily{lc $param} = $init{$key};
    }
  }
  SetDailyNowplayers();

  return 1;
}

sub WriteDaily {
  my ($time) = @_;
  $time = Time() unless defined $time;

  my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime($time);
  my $file = DAILYFILE;
  $file =~ s/%y/$year/g;
  $file =~ s/%m/$mon/g;
  $file =~ s/%d/$mday/g;

  my $config = Config::IniFiles->new(-file => $file);
  if (not defined $config) {
    $config = Config::IniFiles->new();
  }

  my %values = (
    Games => $Daily{games},
    HighestPlayers => $Daily{highestplayers},
    Logins => $Daily{logins},
  );

  my $sect = "$year$mon$mday";
  foreach my $key (keys %values) {
    my $param = $key;
    if ( defined $config->val($sect, $param) ) {
      $config->setval($sect, $param, $values{$key});
    } else {
      $config->newval($sect, $param, $values{$key});
    }
  }

  $config->WriteConfig($file);
}

sub SetDailyNowplayers {
  $Daily{nowplayers} = scalar(keys %Users);
  $Daily{highestplayers} = $Daily{nowplayers} if $Daily{nowplayers} > $Daily{highestplayers};
}

# =================================================================
#     Time functions
# =================================================================

sub Time {
  return time;
}

# time counted inside this program
sub PTime {
  return $Misc{ptime};
}

sub IncreasePTime {
  $Misc{ptime}++;
}

sub ResetPTime {
  $Misc{ptime} = 1;
}

# high resolution of time, used for games
sub RealTime {
  return (TIMEHIRES ? [gettimeofday()] : [Time(), 0]);
}

sub TimeInterval {
  my ($a, $b) = @_;
  # this line is from Time/HiRes.pm's tv_interval()
  my $diff = (${$b}[0] - ${$a}[0]) + ((${$b}[1] - ${$a}[1]) / 1_000_000);
  return round($diff, SCOREDECIMAL);
}

sub ClockChanged {
  my ($old, $new) = @_;
  foreach my $player (values %Users) {
    next unless defined $player;
    foreach my $pn (@{$player->{playernum}}) {
      next unless defined $pn->{pingbuf};
      $pn->{pingbuf}[0] -= $old;
      $pn->{pingbuf}[0] += $new;
    }
  }
  foreach my $ch (@Channels) {
    next unless $ch->{ingame};
    $ch->{game}{timestart}[0] -= $old;
    $ch->{game}{timestart}[0] += $new;
  }
}

# =================================================================
#     Timeout functions
# =================================================================

sub CheckTimeoutOutgame {
  my ($player) = @_;
  return unless $Config->val('Main', 'TimeoutOutgame') > 0;

  my $time = PTime();
  my $s = $player->{socket};
  if ($player->{timeout} + $Config->val('Main', 'TimeoutOutgame') <= $time) {
    $player->{timedout} = 1;
    Send($s, 'pline', 0, [Msg('TimedOut')]);
    Report('connection_error', $s, $s, RMsgDisconnect("Timed out (outgame)", $s));
    CloseConnection($s);
  } elsif ( not $player->{timeoutpinged} ) {
  # send ping
    return unless $Config->val('Main', 'TimeoutPing') > 0;
    return unless ($player->{timeout} + $Config->val('Main', 'TimeoutOutgame') - $Config->val('Main', 'TimeoutPing') <= $time);

    Send($s, 'pline', 0, [Msg('Ping')]);
    SendPlayernum($s, $Users{$s}{slot});
    $player->{timeoutpinged} = 1;
  }
}

sub SetTimeoutIngame {
  my ($s) = @_;

  $Users{$s}{timeoutingame} = PTime();
}

sub UpdateTimeoutIngame {
  my ($s) = @_;
  my $ch = $Users{$s}{channel};
  return unless ($ch->{ingame} and not $ch->{paused});

  $Users{$s}->{timeoutingame} = PTime();
}

sub CheckTimeoutIngame {
  my ($player) = @_;
  return unless $Config->val('Main', 'TimeoutIngame') > 0;

  my $time = PTime();
  my $ch = $player->{channel};
  return unless ($ch->{ingame} and not $ch->{paused} and $player->{alive});
  return unless ($player->{timeoutingame} + $Config->val('Main', 'TimeoutIngame') <= $time);

  $player->{timedout} = 1;
  my $s = $player->{socket};
  Send($s, 'pline', 0, [Msg('TimedOut')]);
  Report('connection_error', $s, $s, RMsgDisconnect("Timed out (ingame)", $s));
  CloseConnection($s);
}

sub PauseTimeoutIngame {
  my ($ch) = @_;

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    $Users{$user}{timeoutingame} -= PTime();
  }
}

sub UnpauseTimeoutIngame {
  my ($ch) = @_;

  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    $Users{$user}{timeoutingame} += PTime();
  }
}

# =================================================================
#     Ban functions
# =================================================================

sub ReadBan {
  my ($default) = @_;
  my $file = BANFILE;

  # reading ban file
  if ( open(IN, "< $file") ) {
    @Ban = ([], []); # raw data, masks
    while (my $line = <IN>) {
      $line =~ tr/\x0D\x0A//d; # strip crlf
      my $comments = ($line =~ s/(#.*)// ? $1 : '');
      $line =~ s/^\s+//; $line =~ s/\s+$//;
      my ($opts, $nick, $host, $expire) = split(/\s+/, $line);
      AddBanRawData($opts, $nick, $host, $expire, $comments);
      AddBanData($opts, $nick, $host);
    }
    close(IN);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open ban config file `$file' to read");
    return undef unless $default;
    @Ban = ([], []);
  }
  return 1;
}

sub WriteBan {
  my $file = BANFILE;

  if ( open(OUT, "> $file") ) {
    foreach ( @{$Ban[BAN_RAW]} ) {
      my ($opts, $nick, $host, $expire, $comments) = @$_;

      my $line = $opts;
      if ($nick ne '') { $line .= ($line ne '' ? ' ' : '') . $nick; }
      if ($host ne '') { $line .= ($line ne '' ? ' ' : '') . $host; }
      if ($expire != 0) { $line .= ($line ne '' ? ' ' : '') . $expire; }
      if ($comments ne '') { $line .= ($line ne '' ? ' ' : '') . $comments; }

      print OUT "$line\n";
    }
    close(OUT);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open ban config file `$file' to write");
    return undef;
  }
  return 1;
}

sub CheckBan {
  my ($nick, $ip, $host) = @_;

  $nick = StripColors(lc $nick);
  $ip = lc $ip;
  $host = lc $host;

  my $result = undef;
  foreach ( @{$Ban[BAN_MASK]} ) {
    my ($opts, $mnick, $mhost) = @$_;

    my $exception = ($opts =~ /e/);
    next if (defined $result and not $exception);
    my $matched = undef;
    $matched = [$mnick, $mhost] if ( $nick =~ /^$mnick$/ and
                                     ($ip =~ /^$mhost$/ or $host =~ /^$mhost$/) );
    next unless defined $matched;

    return undef if $exception;
    $result = $matched;
  }

  return $result;
}

sub CheckBanExpire {
  my $time = Time();
  my @masks = (); # masks to be removed

  foreach ( @{$Ban[BAN_RAW]} ) {
    my ($opts, $nick, $host, $expire, $comments) = @$_;
    next unless $expire > 0;
    push(@masks, [$nick, $host]) if $expire <= $time;
  }
  ( RemoveBanRawData(@$_) and RemoveBanData(@$_) ) foreach (@masks);
}

sub SendBanList {
  my ($s) = @_;
  foreach ( @{$Ban[BAN_RAW]} ) {
    my ($opts, $nick, $host, $expire, $comments) = @$_;
    next if ($nick eq '' or $host eq '');

    my $mask = ($opts ne '' ? "$opts " : "- ") . "$nick $host";
    $mask .= ' ' x (24 - length($mask)) if (24 - length($mask) > 0);
    my $time_str = ($expire > 0 ? scalar(LocalTime($expire)) : '');
    Send($s, 'pline', 0, [Msg('ListBan', $mask, $time_str)]);
  }
}

sub AddBanMask {
  my ($opts, $nick, $host, $expire, $comments) = @_;
  AddBanData($opts, $nick, $host) or return undef;
  AddBanRawData($opts, $nick, $host, $expire, $comments) or return undef;
  return 1;
}

sub AddBanRawData {
  my ($opts, $nick, $host, $expire, $comments) = @_;
  $opts = '' unless defined $opts;
  $nick = StripColors($nick);
  $host = StripColors($host);
  $expire = (defined $expire ? int $expire : 0);
  $comments = '' unless defined $comments;
  push(@{$Ban[BAN_RAW]}, [$opts, $nick, $host, $expire, $comments]);

  return 1;
}

sub AddBanData {
  my ($opts, $nick, $host) = @_;
  return undef if (not defined $nick or $nick eq '' or
                   not defined $host or $host eq '');
  $opts = '' unless defined $opts;

  $opts =~ tr/-//d;
  $nick = StripColors(lc $nick);
  $host = StripColors(lc $host);

  if (not $opts =~ /r/) {
    $nick = BanMaskRegexp($nick);
    $host = BanMaskRegexp($host);
  }

  eval '/^$nick$/; /^$host$/;';
  return undef if $@;

  push(@{$Ban[BAN_MASK]}, [$opts, $nick, $host]);
  return 1;
}

sub RemoveBanRawData {
  my ($nick, $host) = @_;
  return undef if (not defined $nick or $nick eq '' or
                   not defined $host or $host eq '');

  $nick = StripColors(lc $nick);
  $host = StripColors(lc $host);

  my $removed = undef;
  for (my $i=0; $i<@{$Ban[BAN_RAW]}; $i++) {
    my ($opts, $nick2, $host2, $expire, $comments) = @{$Ban[BAN_RAW][$i]};
    next unless ($nick eq lc($nick2) and $host eq lc($host2));

    splice(@{$Ban[BAN_RAW]}, $i, 1);
    $removed = [$opts, $nick2, $host2, $expire, $comments];
    last;
  }

  return $removed;
}

sub RemoveBanData {
  my ($nick, $host) = @_;
  return undef if (not defined $nick or $nick eq '' or
                   not defined $host or $host eq '');

  $nick = StripColors(lc $nick);
  $host = StripColors(lc $host);
  my $rnick = BanMaskRegexp($nick);
  my $rhost = BanMaskRegexp($host);

  my $removed = undef;
  for (my $i=0; $i<@{$Ban[BAN_MASK]}; $i++) {
    my ($opts, $nick2, $host2) = @{$Ban[BAN_MASK][$i]};
    if ($opts =~ /r/) {
      next unless ($nick eq $nick2 and $host eq $host2);
    } else {
      next unless ($rnick eq $nick2 and $rhost eq $host2);
    }

    splice(@{$Ban[BAN_MASK]}, $i, 1);
    $removed = [$opts, $nick2, $host2];
    last;
  }

  return $removed;
}

sub BanMaskRegexp {
  my ($mask) = @_;
  return '' unless defined $mask;

  $mask = quotemeta $mask;
  $mask =~ s/\\\?/.?/g;
  $mask =~ s/\\\*/.*/g;

  return $mask;
}

sub stoiBanExpire {
  my ($str) = @_;
  return 0 if (not defined $str or $str eq '');

  my $time = Time();
  my $expire = $time;
  $expire += $1 * 60 * 60 * 24 if $str =~ s/(\d+)d//i;
  $expire += $1 * 60 * 60 if $str =~ s/(\d+)h//i;
  $expire += $1 * 60 if $str =~ s/(\d+)m//i;
  $expire = 0 if $expire == $time;

  return $expire;
}

# =================================================================
#     Anti-Flood functions
# =================================================================

sub AddAntiFlood {
  my ($s, $length) = @_;
  return 1 if $Config->val('Main', 'AntiFlood') <= 0;

  $Users{$s}{antiflood} += ($Config->val('Main', 'MessagePenalty') + $length);
  if ($Users{$s}{antiflood} > $Config->val('Main', 'AntiFlood')) {
    Report('connection_error', $s, $s, RMsgDisconnect("Excess flood", $s));
    CloseConnection($s);
    return undef;
  }

  return 1;
}

sub UpdateAntiFlood {
  my ($player) = @_;
  return if $Config->val('Main', 'AntiFlood') <= 0;

  $player->{antiflood} -= $Config->val('Main', 'PenaltyPerSecond');
  $player->{antiflood} = 0 if $player->{antiflood} < 0;
}

# =================================================================
#     Cushion functions for client type differences
# =================================================================

sub Playernum {
  my ($s) = @_;
  return ')#)(!@(*3' if $Users{$s}{client} eq CLIENT_TETRIFAST;
  return 'playernum'; # if $Users{$s}{client} eq CLIENT_TETRINET;
}

sub Newgame {
  my ($s) = @_;
  return '*******' if $Users{$s}{client} eq CLIENT_TETRIFAST;
  return 'newgame'; # if $Users{$s}{client} eq CLIENT_TETRINET;
}

# =================================================================
#     Initializations
# =================================================================

sub StartServer {
  srand();

  my $time = Time();
  my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime($time);

  SetSignalHandlers();

  # init variables
  %Users = ();
  @Channels = ();
  $Misc{brokenpipe} = undef;
  $Misc{clients} = {};
  $Misc{closing} = {};
  $Misc{commands} = PlCommands();
  $Misc{command_names} = [sort keys %{$Misc{commands}}];
  $Misc{command_aliases} = {};
  $Misc{ip2host} = {};
  $Misc{lastcheck} = [$time, $min, $hour, [$mday, $time], 0];
  $Misc{listener} = {tetrinet => undef, lookup => undef};
  $Misc{passwords} = [];
  $Misc{readable} = IO::Select->new();
  $Misc{shutdown} = undef;
  $Misc{stacklevel} = 0;
  $Misc{waitinglookup} = {};
  $Misc{writable} = IO::Select->new();
  @COLOR_CODES = ("\x04","\x06","\x0F","\x11","\x05","\x03","\x17","\x0E","\x0C","\x10","\x14","\x08","\x13","\x19","\x18","\x02","\x16","\x1F","\x0B","\x15");
  @COLOR_NAMES = qw[black gray lgray dblue blue lblue dgreen lgreen teal rust red pink purple yellow white bold italic underline];
  $PROGRAM_NAME = 'Perl TetriNET Server v' . VERSION;
  ResetPTime();

  WriteLog("Starting $PROGRAM_NAME...");

  if (TIMEHIRES) {
    eval 'use Time::HiRes qw(gettimeofday);';
    if ($@) {
      Report('error', undef, undef, "ERROR: Cannot locate Time/HiRes.pm");
      die $@;
    }
  }

  print "Reading configurations...\n";

  ReadConfig(1);
  UpdateChannels();

  ReadMsg(1);
  ReadBan(1);
  ReadSecure(1);
  ReadProfile(1);
  ReadWinlist();
  ReadLmsg(1);
  ReadDaily(1);

  print "Running tetrinet server...\n";
  $Misc{listener}{tetrinet} = IO::Socket::INET->new(
    LocalPort => TNETPORT,
    Listen => LISTENQUEUESIZE,
    Proto => 'tcp',
    Reuse => 1,
  ) or (
    Report('error', undef, undef, "ERROR: Cannot create a socket for listening: $!"),
    die "Cannot create a socket for listening: $!\n"
  );
  $Misc{readable}->add($Misc{listener}{tetrinet});
  WriteLog("Listening at tetrinet port " . TNETPORT);

  if (LOOKUPHOST and not NOFORK) {
    print "Running lookup server...\n";
    $Misc{listener}{lookup} = IO::Socket::INET->new(
      LocalPort => LOOKUPPORT,
      Listen => LISTENQUEUESIZE,
      Proto => 'tcp',
      Reuse => 1,
    ) or (
      Report('error', undef, undef, "ERROR: Cannot create a socket for listening: $!"),
      die "Cannot create a socket for listening: $!\n"
    );
    $Misc{readable}->add($Misc{listener}{lookup});
    WriteLog("Listening at lookup port " . LOOKUPPORT);
  }

  print "Completed!\n";

  if (DAEMON) {
    if ( my $result = Daemon() ) {
      Report('error', undef, undef, "ERROR: Cannot be daemon: $result");
      die "Cannot be daemon: $result\n";
    }
  }

  WritePid();
}

# Daemon() - this function is from Proc/Daemon.pm
sub Daemon {
  my $pid;

  $pid = fork();
  if (defined $pid) {
    exit 0 if $pid != 0;
  } else {
    return "fork() failed: $!";
  }

  my $sid = POSIX::setsid() or return "setsid() failed";

  $pid = fork();
  if (defined $pid) {
    exit 0 if $pid != 0;
  } else {
    return "fork() failed: $!";
  }

  umask 022;

  open(STDIN,  "+> /dev/null");
#  open(STDOUT, "+>&STDIN");
  open(STDOUT, "+>&STDIN") if not DEBUG; # DEBUGGING
#  open(STDERR, "+>&STDIN");
  open(STDERR, "+>&STDIN") if not DEBUG; # DEBUGGING

  open(STDOUT, ">> ./logs/debug.log") if DEBUG; # DEBUGGING
  open(STDERR, ">> ./logs/debug.log") if DEBUG; # DEBUGGING

  return undef;
}

sub ReadConfig {
  my ($default) = @_;
  my $file = CONFIGFILE;

  my $config = Config::IniFiles->new(-file => $file);
  if (not defined $config) {
    Report('error', undef, undef, "ERROR: Cannot open game config file `$file' to read");
    return undef unless $default;
    $config = Config::IniFiles->new();
  }

  my %init = ( # default settings
    '[Main] ClientTetrinet' => 1,
    '[Main] ClientTetrifast' => 1,
    '[Main] ClientQuery' => 1,
    '[Main] UsersFromSameIP' => 0,
    '[Main] MaxChannels' => 0,
    '[Main] UserMadeChannel' => 1,
    '[Main] InterceptGmsgPause' => 1,
    '[Main] InterceptGmsgPing' => 1,
    '[Main] ReservedName' => 'server -',
    '[Main] SpecTeamName' => 'spec',
    '[Main] StripGmsgColor' => 1,
    '[Main] StripNameColor' => 0,
    '[Main] TimeoutIngame' => 60,
    '[Main] TimeoutOutgame' => 600,
    '[Main] TimeoutPing' => 60,
    '[Main] VerifyClient' => 0,
    '[Main] VerifyStrictly' => 0,
    '[Main] AntiFlood' => 800,
    '[Main] MessagePenalty' => 100,
    '[Main] PenaltyPerSecond' => 50,
    '[Locale] Default' => 'en',
    '[Locale] en' => './locale/en.msg',
#    '[Locale] ja' => './locale/ja.msg',
    '[FilePath] motd' => './pts.motd',
#    '[FilePath] news' => './pts.news',
    '[Authority] User' => 0,
    '[Authority] Moderator' => 1,
    '[Authority] Operator' => 5,
    '[Authority] Administrator' => 9,
    '[Authority] Start' => 1,
    '[Authority] Stop' => 1,
    '[Authority] Pause' => 1,
    '[Command] Alias' => 5,
    '[Command] Auth' => 0,
    '[Command] Ban' => 7,
    '[Command] Board' => 0,
    '[Command] Broadcast' => 3,
    '[Command] Dstats' => 0,
    '[Command] File' => 3,
    '[Command] Find' => 0,
    '[Command] Grant' => 6,
    '[Command] Gstats' => 0,
    '[Command] Help' => 0,
    '[Command] Helpop' => 0,
    '[Command] Info' => 0,
    '[Command] Join' => 0,
    '[Command] Kick' => 5,
    '[Command] Kill' => 7,
    '[Command] Lang' => -1,
    '[Command] List' => 0,
    '[Command] Lmsg' => 0,
    '[Command] Load' => 8,
    '[Command] Motd' => -1,
    '[Command] Move' => 1,
    '[Command] Msg' => 0,
    '[Command] Msgto' => 0,
    '[Command] News' => -1,
    '[Command] Passwd' => 0,
    '[Command] Pause' => 1,
    '[Command] Ping' => 0,
    '[Command] Quit' => 0,
    '[Command] Reg' => 5,
    '[Command] Reset' => 8,
    '[Command] Save' => 8,
    '[Command] Score' => 0,
    '[Command] Set' => 0,
    '[Command] Shutdown' => 9,
    '[Command] Start' => 1,
    '[Command] Stop' => 1,
    '[Command] Teleport' => 5,
    '[Command] Time' => -1,
    '[Command] Topic' => 4,
    '[Command] Unban' => 7,
    '[Command] Unreg' => 5,
    '[Command] Version' => -1,
    '[Command] Who' => 0,
    '[Command] Winlist' => 0,
    '[Command] BoardDelete' => 5,
    '[Command] BoardWrite' => 0,
    '[Command] DefaultStartCount' => 0,
    '[Command] DisplayIP' => 5,
    '[Command] HelpExplanation' => 0,
    '[Command] NoKickTime' => 0,
    '[Command] PageBoard' => 10,
    '[Command] PageHelp' => 20,
    '[Command] PageList' => 20,
    '[Command] PageWinlist' => 10,
#    '[CommandAlias] Op' => 'auth op',
#    '[CommandAlias] Admin' => 'auth admin',
#    '[CommandAlias] Wall' => 'broadcast',
#    '[CommandAlias] Exit' => 'quit',
    '[Report] Admin' => '1 -1',
    '[Report] Auth' => '1 -1',
    '[Report] Ban' => '1 -1',
    '[Report] Board' => '1 -1',
    '[Report] Chat' => '0 -1',
    '[Report] Connection' => '1 -1',
    '[Report] ConnectionError' => '1 -1',
    '[Report] Debug' => '0 -1',
    '[Report] Error' => '1 -1',
    '[Report] Game' => '0 -1',
    '[Report] Join' => '0 -1',
    '[Report] Lookup' => '0 -1',
    '[Report] Move' => '0 -1',
    '[Report] Msg' => '0 -1',
    '[Report] Profile' => '1 -1',
    '[Report] Query' => '0 -1',
    '[Report] RawReceive' => 0,
    '[Report] RawSend' => 0,
    '[Report] Set' => '1 -1',
    '[Report] Team' => '0 -1',
    '[Report] StripColors' => '1 1',
    '[ChannelDefault] Name' => 'tetrinet',
    '[ChannelDefault] Priority' => 50,
    '[ChannelDefault] MaxPlayers' => MAXPLAYERS,
    '[ChannelDefault] Setable' => 4,
    '[ChannelDefault] AnnounceRank' => 1,
    '[ChannelDefault] AnnounceScore' => 1,
    '[ChannelDefault] AnnounceStats' => 0,
    '[ChannelDefault] GameStatsMsg' => 0,
    '[ChannelDefault] Winlist' => 0,
    '[ChannelDefault] Playable' => 1,
    '[ChannelDefault] Tetrinet' => 1,
    '[ChannelDefault] Tetrifast' => 0,
    '[ChannelDefault] GameType' => 1,
    '[ChannelDefault] Stack' => '0 0 0 0 0 0',
    '[ChannelDefault] StartingLevel' => 1,
    '[ChannelDefault] LinesPerLevel' => 2,
    '[ChannelDefault] LevelIncrease' => 1,
    '[ChannelDefault] LinesPerSpecial' => 1,
    '[ChannelDefault] SpecialAdded' => 1,
    '[ChannelDefault] SpecialCapacity' => 18,
    '[ChannelDefault] ClassicRules' => 1,
    '[ChannelDefault] AverageLevels' => 1,
    '[ChannelDefault] SDTimeout' => 0,
    '[ChannelDefault] SDLinesPerAdd' => 1,
    '[ChannelDefault] SDSecsBetweenLines' => 30,
    '[ChannelDefault] SDMessage' => q[Time's up! It's SUDDEN DEATH MODE!],
    '[ChannelDefault] BlockLeftL' => 14,
    '[ChannelDefault] BlockLeftZ' => 14,
    '[ChannelDefault] BlockSquare' => 15,
    '[ChannelDefault] BlockRightL' => 14,
    '[ChannelDefault] BlockRightZ' => 14,
    '[ChannelDefault] BlockHalfcross' => 14,
    '[ChannelDefault] BlockLine' => 15,
    '[ChannelDefault] SpecialAddline' => 19,
    '[ChannelDefault] SpecialClearline' => 16,
    '[ChannelDefault] SpecialNukefield' => 3,
    '[ChannelDefault] SpecialRandomclear' => 14,
    '[ChannelDefault] SpecialSwitchfield' => 3,
    '[ChannelDefault] SpecialClearspecial' => 11,
    '[ChannelDefault] SpecialGravity' => 6,
    '[ChannelDefault] SpecialQuakefield' => 14,
    '[ChannelDefault] SpecialBlockbomb' => 14,
  );

  foreach my $key (keys %init) {
    my ($sect, $param) = ($key =~ /^\[([^\]]*)\]\s*(\w*)$/);
    next if defined $config->val($sect, $param);
    $config->newval($sect, $param, $init{$key});
  }

  my %aliases = ();
  foreach my $name ( $config->Parameters('CommandAlias') ) {
    $aliases{lc $name} = lc $config->val('CommandAlias', $name);
  }
  $Misc{command_aliases} = \%aliases;

  $Config = $config;
  return 1;
}

sub ReadMsg {
  my ($default) = @_;

  my %init = ( # default settings
    Banned => 'You are banned from server!',
    NicknameAlreadyExists => 'Nickname already exists on server!',
    NicknameIsEmpty => 'Nickname is empty!',
    QueryAccessNotAllowd => 'Query access not allowed!',
    ReservedName => 'You cannot use the nickname!',
    ServerIsFull => 'Server is Full!',
    TetrifastClientNotAllowd => 'TetriFAST client not allowed!',
    TetrinetClientNotAllowd => 'TetriNET client not allowed!',
    TooLongNickname => 'Too long nickname!',
    TooManyArguments => 'Too many arguments! No spaces are allowed for nickname.',
    TooManyHostConnections => 'Too many host connections!',
    VersionDifference => q[TetriNET version (%0) does not match Server's (%1)!],

    Format => '<dblue>Format: <dblue>',
    FormatAdmin => '%0%1 <blue>[password]',
    FormatAlias => '%0%1 <blue><real nick> [alias nick]',
    FormatAuth => '%0%1 <blue>[<USER|OP|ADMIN|0-9> [password]]',
    FormatBan => '%0%1 <blue>[[-er] <nick mask> <host mask>] [expire]',
    FormatBoard => '%0%1 <blue>[<-w> <message>|<-d> <no>]',
    FormatBroadcast => '%0%1 <blue><message>',
    FormatDstats => '%0%1',
    FormatFile => '%0%1 <blue>[file name] [player number(s)]',
    FormatFind => '%0%1 <blue><keyword>',
    FormatGrant => '%0%1 <blue><nickname> [USER|OP|ADMIN|0-9]',
    FormatGstats => '%0%1',
    FormatHelp => '%0%1 <blue>[-abol|command]',
    FormatHelpop => '%0%1',
    FormatInfo => '%0%1 <blue>[nickname]',
    FormatJoin => '%0%1 <blue><#channel|channel number>',
    FormatKick => '%0%1 <blue><player number(s)>',
    FormatKill => '%0%1 <blue><nickname> [expire]',
    FormatLang => '%0%1 <blue>[DEFAULT|EN|JA]',
    FormatList => '%0%1',
    FormatLmsg => '%0%1 <blue><nickname> <message>',
    FormatLoad => '%0%1 <blue><BAN|CONFIG|MSG|SECURE>',
    FormatMotd => '%0%1',
    FormatMove => '%0%1 <blue>[player number|0|8] <new player number>',
    FormatMsg => '%0%1 <blue><nickname|player number(s)> <message>',
    FormatMsgto => '%0%1 <blue><nickname>',
    FormatNews => '%0%1',
    FormatOp => '%0%1 <blue>[password]',
    FormatPasswd => '%0%1 <blue><new password>',
    FormatPause => '%0%1',
    FormatPing => '%0%1',
    FormatQuit => '%0%1',
    FormatReg => '%0%1 <blue><nickname> <password>',
    FormatReset => '%0%1 <blue>[-b] [winlist number|ALL]',
    FormatSave => '%0%1 <blue><BAN>',
    FormatScore => '%0%1 <blue>[nickname|teamname]',
    FormatSet => '%0%1 <blue>[<key> [value1] [value2] [...]]',
    FormatShutdown => '%0%1 <blue>[-cnr]',
    FormatStart => '%0%1 <blue>[count]',
    FormatStop => '%0%1',
    FormatTeleport => '%0%1 <blue><nickname> [#channel|channel number]',
    FormatTime => '%0%1',
    FormatTopic => '%0%1 <blue><channel topic>',
    FormatUnban => '%0%1 <blue>[<nick mask> <host mask>]',
    FormatUnreg => '%0%1 <blue><nickname>',
    FormatVersion => '%0%1',
    FormatWho => '%0%1 <blue>[#channel|channel number]',
    FormatWinlist => '%0%1 <blue>[#channel|channel number]',

    ExplainAlias => 'Registers a real nickname for an alias nickname',
    ExplainAlias2 => q[If you don't specify <blue>alias nick<blue>, your using nick will be used],
    ExplainAlias3 => '<blue>/alias -<blue> unregisters the real nickname',
    ExplainAuth => 'Changes your authority',
    ExplainBan => 'Prevents player(s) from connecting',
    ExplainBan2 => 'Expire format: nDnHnM (ex. 1h30m for 90 minutes ban)',
    ExplainBoard => 'Accesses to the message board',
    ExplainBoard2 => '<blue>-w message<blue> writes a message, <blue>-d no<blue> deletes a message',
    ExplainBroadcast => 'Sends a message to all online players',
    ExplainDstats => 'Displays current daily statistics',
    ExplainFile => 'Displays a message file',
    ExplainFind => 'Searchs players on the server',
    ExplainGrant => 'Gives authority for others',
    ExplainGstats => 'Displays current/last game statistics',
    ExplainGstats2 => '<blue>LT:<blue> lifetime, <blue>P:<blue> dropped pieces, <blue>S:<blue> speed (pieces per minute)',
    ExplainGstats3 => '<blue>SB:<blue> used special blocks, <blue>L:<blue> cleared lines, <blue>T:<blue> tetrises',
    ExplainGstats4 => '<blue>CS:<blue> classic style added lines, <blue>Y:<blue> yields (CS/L)',
    ExplainGstats5 => '<blue>UD:<blue> unsolved data (P and L may be miscounted in this range)',
    ExplainHelp => 'Lists player commands',
    ExplainHelp2 => '<blue>-a<blue> displays all commands, <blue>-b<blue> displays basic commands',
    ExplainHelp3 => '<blue>-o<blue> displays operator commands, <blue>-l<blue> displays command aliases',
    ExplainHelp4 => 'If you specify <blue>command<blue>, displays explanation of the command',
    ExplainHelpop => 'Lists operator commands',
    ExplainInfo => 'Displays player information',
    ExplainJoin => 'Joins or creates a tetrinet channel',
    ExplainKick => 'Kicks out player(s) from the server',
    ExplainKill => 'Does stealth kick and temporary ban',
    ExplainKill2 => 'Expire format: nDnHnM (ex. 1h30m for 90 minutes ban)',
    ExplainLang => 'Changes server message language',
    ExplainList => 'Lists available tetrinet channels',
    ExplainLmsg => 'Leaves a message',
    ExplainLoad => 'Reloads configuration files',
    ExplainMotd => 'Displays motd',
    ExplainMove => 'Moves a player to a new player number',
    ExplainMove2 => '<blue>0<blue> compacts numbers, <blue>8<blue> shuffles numbers',
    ExplainMsg => 'Sends a private message to player(s)',
    ExplainMsgto => 'Sets a player to send /msg to',
    ExplainNews => 'Displays news',
    ExplainPasswd => 'Changes your password',
    ExplainPause => 'Pauses/Unpauses current game',
    ExplainPing => 'Replies pong and displays network latency',
    ExplainQuit => 'Quits the server',
    ExplainReg => 'Registers a nick with password',
    ExplainReset => 'Clears winlist records',
    ExplainReset2 => '<blue>b<blue> backups old data',
    ExplainSave => 'Writes out configuration files to disk',
    ExplainScore => 'Displays current ranks',
    ExplainSet => 'Chenges the channel config',
    ExplainShutdown => 'Halts the server',
    ExplainShutdown2 => '<blue>n<blue> halts now, <blue>r<blue> re-launches',
    ExplainStart => 'Starts new game with count',
    ExplainStop => 'Stops current game',
    ExplainTeleport => 'Forces a player to join a channel',
    ExplainTime => 'Displays the server time',
    ExplainTopic => 'Sets the channel topic',
    ExplainTopic2 => '<blue>-<blue> removes',
    ExplainUnban => 'Removes a ban mask',
    ExplainUnreg => 'Removes password from a registered nick',
    ExplainVersion => 'Displays the server version',
    ExplainWho => 'Lists all online players',
    ExplainWinlist => 'Displays the top players',

    SetHelp => '<dblue>The following keys are setable:',
    SetHelpAnnounce => '<blue>ANNOUNCE<blue> - Announce configuration',
    SetHelpBasic => '<blue>BASIC<blue> - Basic channel configuration',
    SetHelpBlock => '<blue>BLOCK<blue> - Frequency of blocks',
    SetHelpGametype => '<blue>GAMETYPE<blue> - Configuration for game type and playable clients',
    SetHelpRules => '<blue>RULES<blue> - Game rules',
    SetHelpSd => '<blue>SD<blue> - Configuration for sudden death mode',
    SetHelpSpecial => '<blue>SPECIAL<blue> - Frequency of special blocks',
    SetFormatAnnounce => '<red>/set ANNOUNCE <blue>AnnounceRank AnnounceScore AnnounceStats GameStatsMsg',
    SetFormatBasic => '<red>/set BASIC <blue>ChannelName MaxPlayers Priority Persistant',
    SetFormatBlock => '<red>/set BLOCK <blue>LeftL LeftZ Square RightL RightZ HalfCross Line',
    SetFormatGametype => '<red>/set GAMETYPE <blue>Playable Tetrinet Tetrifast GameType',
    SetFormatRules => '<red>/set RULES <blue>StartingLevel LinesPerLevel LevelIncrease LinesPerSpecial SpecialAdded SpecialCapacity ClassicRules AverageLevels',
    SetFormatSd => '<red>/set SD <blue>Timeout LinesPerAdd SecsBetweenLines',
    SetFormatSdmsg => q[<red>/set SDMSG <blue>Message<gray>(`-' for empty)],
    SetFormatSpecial => '<red>/set SPECIAL <blue>A C N R S B G Q O',
    SetFormatStack => '<red>/set STACK <blue>PL1 PL2 PL3 PL4 PL5 PL6',

    AnnounceGameStats => '<dblue>Game Statistics <dgreen>- <black>%0<black> seconds played',
    AnnouncePlayerStats0 => '<blue>%0<blue>  <dgreen>LT:<dgreen>%1<dgreen>s<dgreen>  <dgreen>S:<dgreen>%4<dgreen>ppm<dgreen>  <dgreen>SB:<dgreen>%5  <dgreen>L:<dgreen>%6  <dgreen>UD:<dgreen>%3',
    AnnouncePlayerStats1 => '<blue>%0<blue>  <dgreen>LT:<dgreen>%1<dgreen>s<dgreen>  <dgreen>S:<dgreen>%4<dgreen>ppm<dgreen>  <dgreen>P:<dgreen>%2  <dgreen>L:<dgreen>%6  <dgreen>CS:<dgreen>%8  <dgreen>T:<dgreen>%7',
    AnnouncePlayerStats2 => '<blue>%0<blue>  <dgreen>LT:<dgreen>%1<dgreen>s<dgreen>  <dgreen>S:<dgreen>%4<dgreen>ppm<dgreen>  <dgreen>L:<dgreen>%6  <dgreen>Y:<dgreen>%9<dgreen>%<dgreen>  <dgreen>UD:<dgreen>%3',
    AnnounceRank => '<blue>%0.<blue> <rust>%1<rust>%2',
    AnnounceScore1 => '%0  <dblue>Points %1(%2)  Rank %3',
    AnnounceScore2 => '%0  <dblue>Lines %1(%2)  Rank %3',
    AnnounceScore3 => '%0  <dblue>Lifetime %1(%2)  Rank %3',
    AnnounceScore4 => '%0  <dblue>Lifetime %1(%2)  Rank %3',
    Authority => q[<red>%0's authority level: %0],
    BannedUser => '<dblue>Banned user: <blue>%0',
    Broadcast => '<dblue><bold><%0><bold> %1',
    CannotChangeTeamWhileInGame => '<red>Cannot change team while game is in play',
    CannotCreateAnyMoreChannels => '<red>Cannot create any more channels',
    CannotCreateNewChannel => '<red>Cannot create new channel',
    CannotDeprive => '<red>You do not have permission to deprive him/her of authority',
    CannotGiveHigherAuthority => '<red>You cannot give higher authority level than you have',
    CannotKickHimHerInNSeconds => '<red>Cannot kick him/her in %0 seconds',
    CannotUseCommandNow => '<red>Cannot use that command just now',
    Certified => '<blue>You have been certified',
    ChangedPassword => '<red>Changed password',
    ChangedSettings => '<teal>%0 changed channel settings <blue>%1<blue> to <black>%2',
    ChangedTopic => '<teal>%0 changed channel topic to <black>%1',
    ChannelIsFull => '<dblue>That channel is <red>FULL',
    ChannelNotExists => '<red>That channel not exists on this server',
    ColorChnoCurrent => '<red>%0<red>',
    ColorChnoRegular => '<blue>%0<blue>',
    ColorChnameCurrent => '<red>%0<red>',
    ColorChnameRegular => '<blue>%0<blue>',
    ColorChnameUnplayable => '<gray>%0<gray>',
    ColorCommandUnusable => '<gray>',
    ColorCommandUsable => '<red>',
    ColorMyname => '<red>%0<red>',
    ColorScorePlayer => '<black>%0<black>',
    ColorScoreTeam => '<rust>%0<rust>',
    CompactedPlayers => '<gray>Compacted players by %0',
    CreatedChannel => '<teal>Created new channel - <blue>%0',
    CurrentSettings => '<dblue>Current Setting: <black>%0',
    Dstats => '<dblue>Daily Statistics',
    Dstats1 => '<dgreen>Logins:<dgreen> %2	<dgreen>Online Players:<dgreen> %3',
    Dstats2 => '<dgreen>Games:<dgreen> %0	<dgreen>Highest Players:<dgreen> %1',
    FailedToAddBanMask => '<red>Failed to add ban mask: <blue>%0',
    FileFrom => '<dblue>File messages from %0:',
    FrequencyMustAddUpTo100 => '<red>Blocks/Specials frequency must add up to 100',
    GameCurrentlyUnavailable => '<red>The game is currently unavailable',
    GameIsNotBeingPlayed => '<red>Game is not being played',
    GamePaused => '* GAME PAUSED BY %0',
    GameStarted => '<gray>Game start has been requested by %0',
    GameStopped => '<gray>Game has been stopped by %0',
    GameUnpaused => '* GAME UNPAUSED BY %0',
    GotTeleported => '<teal>You have been teleported to <blue>%1<blue> by %0',
    Granted => '<dblue>You have been granted by %0',
    HasJoinedChannelIn => '<teal>%0 has joined channel %1',
    HasJoinedChannelOut => '<gray>%0 has joined channel %1',
    InfoA => q[<dblue>Info 1 - User's Current Session],
    InfoA1 => '<dgreen>Nick:<dgreen> %0	<dgreen>Team:<dgreen> %1',
    InfoA2 => '<dgreen>Channel:<dgreen> %2	<dgreen>Slot:<dgreen> %3',
    InfoA3 => '<dgreen>IP Address:<dgreen> %4	<dgreen>Hostname:<dgreen> %5',
    InfoA4 => '<dgreen>Client:<dgreen> %6	<dgreen>Idle Time:<dgreen> %7 <dgreen>s<dgreen>',
    InfoA5 => '<dgreen>Ping:<dgreen> <dgreen>Latest.<dgreen> %8 <dgreen>s<dgreen>	<dgreen>Ave.<dgreen> %9 <dgreen>s<dgreen>',
    InfoB => q[<dblue>Info 2 - User's Profile],
    InfoB1 => '<dgreen>Nick:<dgreen> %0  %2',
    InfoB2 => '<dgreen>RegdTeam:<dgreen> %4	<dgreen>Authority:<dgreen> %3',
    InfoB3 => '<dgreen>Logins:<dgreen> %6	<dgreen>Last Login:<dgreen> %7',
    InfoB4 => '<dgreen>Total Time:<dgreen> %8 <dgreen>mins<dgreen>	<dgreen>Lang:<dgreen> %5',
    InfoB5 => '<dgreen>Games played:<dgreen> %9',
    InfoBRegistered => '<purple>[REGISTERED]<purple>',
    InfoMore => '<dblue>Type <red>%0<red> for more information',
    InGameDisplay => 'G',
    InvalidCommand => '<red>Invalid /command',
    InvalidParameters => '<red>Invalid Parameters',
    InvalidPassword => '<red>Invalid Password',
    JoinedChannel => '<teal>Joined existing channel - <blue>%0',
    Kicked => '<dblue>%0 kicked %1',
    LeftMessage => '<dblue>Left the message to %0',
    ListingBan => '<dblue>User Ban List (<blue>-e<blue> = exception ban, <blue>-r<blue> = regular expression)',
    ListingBoard => '<dblue>Message Board (Page %0)',
    ListingChannel => '<dblue>TetriNET Channel Lister (Type <red>/join<red> <blue>#channelname<blue>)',
    ListingFileList => '<dblue>Available File List',
    ListingHelpAdmin => '<dblue>%0 - Admin Commands:',
    ListingHelpAlias => '<dblue>%0 - Command Aliases:',
    ListingHelpAll => '<dblue>%0 - All Commands:',
    ListingHelpBasic => '<dblue>%0 - Basic Commands:',
    ListingLmsg => '<dblue>There are left messages for you:',
    ListingWhoAll => '<dblue>[Channel] Nickname(<gray>Team<gray>)',
    ListingWhoOne => '<dblue>Nickname    	Team',
    ListingWinlist => '<blue>Rank %0-%1 Winlist',
    ListBan => '<black>%0	%1',
    ListBoard => '<black><rust>%0.<rust> <blue><%1><blue> %3 <gray>[%2]',
    ListChannelFull => '<dblue>(%0) %1 [<red>%2/%3<red> <dgreen>%4<dgreen>] <dblue>%6',
    ListChannelOpen => '<dblue>(%0) %1 [<blue>%2/%3<blue> <dgreen>%4<dgreen>] <dblue>%6',
    ListFind => '<blue>%0<blue> on <dblue>%1<dblue>',
    ListLmsg => '<black><blue><%0><blue> %2 <gray>[%1]',
    ListWinlist => '<blue>%0 <dblue>- <black>%1',
    ListWinlistPlayer => '%0. %1 - Player %2',
    ListWinlistTeam => '%0. %1 - Team %2',
    ListTooLong => '<dblue>List too Long - Type <red>%0<red> for more',
    LoadedConfiguration => '<red>Loaded %0 configuration',
    CouldNotLoadConfiguration => '<red>Could not load %0 configuration',
    Locale => '<dblue>Language: <red>%0',
    MessageDeletedFromMessageBoard => '<red>Message has been deleted from the Message Board',
    MessageWrittenToMessageBoard => '<red>Message has been written to the Message Board',
    Msg => '<dblue>( /msg %0 ) <black>%1',
    NA => 'N/A',
    NickAlreadyRegistered => '<red>That nickname already registered',
    NickNotRegistered => '<red>That nickname not registered',
    NoEntryFound => '<red>No entry was found for <blue>%0<blue>',
    NoMatchForQuery => '<red>No match for the query',
    NoOneIsAllowedToPlayGame => '<red>No one is allowed to play game',
    NoPermissionToCommand => '<red>You do not have access to that command',
    NoPermissionToPause => '<red>You do not have permission to pause/unpause game',
    NoPermissionToPauseGmsg => '* You do not have permission to pause/unpause game',
    NoPermissionToStart => '<red>You do not have permission to start game',
    NoPermissionToStop => '<red>You do not have permission to stop game',
    NoScoring => '<red>This/that channel is set to no scoring',
    NoSuchBanMask => '<red>No such ban mask',
    NotPlayable => '<red>This channel is not allowed to play games',
    NotSetable => '<red>You do not have permission to change this channel configuration',
    PausedDisplay => 'P',
    Ping => '<red>PING!',
    PlayerNotOnline => '<red>Player <blue>%0<blue> not online',
    Pong => '<dblue><red>PONG!<red> - <blue>%0<blue>s (ave. <blue>%1<blue>s)',
    Registered => '<red>Registered <blue>%0<blue> successfully',
    RegisteredAlias => '<red>Registered alias <blue>%1<blue> for <blue>%0<blue>',
    RegisteredNickEnterPassword => '<blue>Your nick is registered. Please enter your password:',
    Report => '<gray>Report: %0',
    ResetWinlistFailed => '<red>Failed to reset winlist %0 (%1)',
    ResetWinlistSucceeded => '<red>Succeeded to reset winlist %0 (%1)',
    SavedConfiguration => '<red>Saved %0 configuration',
    CouldNotSaveConfiguration => '<red>Could not save %0 configuration',
    SentFile => '<dblue>File messages have been sent to %0',
    SentPrivateMessage => '<dblue>Private message has been sent to %0',
    ServerDownInNSeconds => '<red>The server is going down in %0 seconds',
    ServerDownWhenCurrentGamesEnded => '<red>The server will be shut down when all current games are ended',
    ServerNotGoingToDown => '<red>The server is not going to shut down',
    ServerStoppedToDown => '<red>The server stopped to shut down',
    SetMsgto => '<dblue>/msg will be sent to <red>%0<red> after this',
    NoSetMsgto => '<dblue>/msg will be sent to someone you specify in each /msg',
    ShuffledPlayers => '<gray>Shuffled players by %0',
    StartingCountStarted => '<red><bold>Starting game in %0 counts',
    StartingCountStopped => '<red><bold>Starting count has been stopped',
    Teleported => '<teal>%0 has been teleported to <blue>%1<blue>',
    ThereAreNoMessages => '<red>There are no messages',
    Time => '<blue>%0',
    TimedOut => '<red>You have timed out. Disconnecting.',
    UnavailableWhileInGame => '<red>Command unavailable while game is in play',
    UnbannedUser => '<dblue>Unbanned user: <blue>%0',
    Unregistered => '<red>Unregistered <blue>%0<blue> successfully',
    UnregisteredAlias => '<red>Unregistered real nickname for <blue>%0<blue>',
    Verified => '<blue>Your client has been verified',
    Verifying0 => '<red>Server is verifying your client',
    Verifying1 => '<red>Please wait patiently for 15 seconds',
    VerifyingGmsg0 => 'PLEASE WAIT - do NOT move/drop/rotate/etc pieces for 15 seconds',
    Version => '<blue>%0',
    WhoAllChannel => '<blue>[%1] %2',
    WhoAllPlayer => '<dgreen>%0<dgreen><gray>%1<gray>',
    WhoAllOnlinePlayers => '<dblue>Total number of players online: <bold>%0',
    WhoOnePlayer => '<dblue>(<blue>%0<blue>) <dgreen>%1	<gray>%2	<black>%3(%4)',
    YouAreNotRegistered => '<red>You are not registered',
  );

  my $result = 1;
  foreach my $lockey ( $Config->Parameters('Locale') ) {
    next if $lockey eq 'Default';
    my $locale = lc $lockey;
    my $file = $Config->val('Locale', $lockey);

    my $config = Config::IniFiles->new(-file => $file);
    if (not defined $config) {
      Report('error', undef, undef, "ERROR: Cannot open messages config file `$file' to read");
      ($result = undef, next) unless $default;
      $config = Config::IniFiles->new();
    }

    my $sect = '';
    foreach my $key (keys %init) {
      my $param = $key;
      next if defined $config->val($sect, $param);
      $config->newval($sect, $param, $init{$key});
    }
    $Msg{$locale} = $config;
  }

  return $result;
}

sub ReadSecure {
  my ($default) = @_;
  my $file = SECUREFILE;

  my $config = Config::IniFiles->new(-file => $file);
  if (not defined $config) {
    Report('error', undef, undef, "ERROR: Cannot open secure config file `$file' to read");
    return undef unless $default;
    $config = Config::IniFiles->new();
  }

  my $crypted = $config->val('Secure', 'Crypted');
  my @passwords = ('');
  for (my $i=1; $i<=9; $i++) {
    push(@passwords, $config->val('Secure', "Password$i"));
  }
  # extension for 10 or more number of authority levels
  for (my $i=10; ; $i++) {
    last unless defined $config->val('Secure', "Password$i");
    push(@passwords, $config->val('Secure', "Password$i"));
  }

  if (not $crypted) {
    foreach my $pass (@passwords) {
      $pass = CryptPassword( StripColors($pass) );
    }
  }

  $Misc{passwords} = \@passwords;

  return 1;
}

sub InitialUserData {
  return (
    alive => undef,
    antiflood => 0,
    channel => undef,
    checking => [undef, undef],
    client => '',
    field => EmptyField(),
    gs => {InitialGameStats()},
    host => undef,
    idletime => PTime(),
    ip => undef,
    msgto => '',
    nick => '',
    ping => [],
    playernum => [],
    profile => undef,
    recvbuf => '',
    sendbuf => '',
    slot => undef,
    socket => undef,
    team => '',
    timedout => undef,
    timeout => PTime(),
    timeoutingame => undef,
    timeoutpinged => undef,
    verified => undef,
    version => undef,
  );
}

sub InitialChannelData {
  return (
    announcerank => $Config->val('ChannelDefault', 'AnnounceRank'),
    announcescore => $Config->val('ChannelDefault', 'AnnounceScore'),
    announcestats => $Config->val('ChannelDefault', 'AnnounceStats'),
    game => {
      count => 0,
      players => [],
      start => [],
      timeend => undef,
      timestart => undef,
    },
    gamestatsmsg => $Config->val('ChannelDefault', 'GameStatsMsg'),
    ingame => 0,
    maxplayers => $Config->val('ChannelDefault', 'MaxPlayers'),
    name => '',
    paused => 0,
    persistant => 0,
    players => [undef],
    playable => $Config->val('ChannelDefault', 'Playable'),
    priority => $Config->val('ChannelDefault', 'Priority'),
    reserved => [undef],
    sc => undef,
    sd => undef,
    setable => $Config->val('ChannelDefault', 'Setable'),
    tetrinet => $Config->val('ChannelDefault', 'Tetrinet'),
    tetrifast => $Config->val('ChannelDefault', 'Tetrifast'),
    topic => '',
    welcomemessage => '',
    winlist => $Config->val('ChannelDefault', 'Winlist'),
    gametype => $Config->val('ChannelDefault', 'GameType'),
    stack => $Config->val('ChannelDefault', 'Stack'),
    startinglevel => $Config->val('ChannelDefault', 'StartingLevel'),
    linesperlevel => $Config->val('ChannelDefault', 'LinesPerLevel'),
    levelincrease => $Config->val('ChannelDefault', 'LevelIncrease'),
    linesperspecial => $Config->val('ChannelDefault', 'LinesPerSpecial'),
    specialadded => $Config->val('ChannelDefault', 'SpecialAdded'),
    specialcapacity => $Config->val('ChannelDefault', 'SpecialCapacity'),
    classicrules => $Config->val('ChannelDefault', 'ClassicRules'),
    averagelevels => $Config->val('ChannelDefault', 'AverageLevels'),
    sdtimeout => $Config->val('ChannelDefault', 'SDTimeout'),
    sdlinesperadd => $Config->val('ChannelDefault', 'SDLinesPerAdd'),
    sdsecsbetweenlines => $Config->val('ChannelDefault', 'SDSecsBetweenLines'),
    sdmessage => $Config->val('ChannelDefault', 'SDMessage'),
    blockleftl => $Config->val('ChannelDefault', 'BlockLeftL'),
    blockleftz => $Config->val('ChannelDefault', 'BlockLeftZ'),
    blocksquare => $Config->val('ChannelDefault', 'BlockSquare'),
    blockrightl => $Config->val('ChannelDefault', 'BlockRightL'),
    blockrightz => $Config->val('ChannelDefault', 'BlockRightZ'),
    blockhalfcross => $Config->val('ChannelDefault', 'BlockHalfcross'),
    blockline => $Config->val('ChannelDefault', 'BlockLine'),
    specialaddline => $Config->val('ChannelDefault', 'SpecialAddline'),
    specialclearline => $Config->val('ChannelDefault', 'SpecialClearline'),
    specialnukefield => $Config->val('ChannelDefault', 'SpecialNukefield'),
    specialrandomclear => $Config->val('ChannelDefault', 'SpecialRandomclear'),
    specialswitchfield => $Config->val('ChannelDefault', 'SpecialSwitchfield'),
    specialclearspecial => $Config->val('ChannelDefault', 'SpecialClearspecial'),
    specialgravity => $Config->val('ChannelDefault', 'SpecialGravity'),
    specialquakefield => $Config->val('ChannelDefault', 'SpecialQuakefield'),
    specialblockbomb => $Config->val('ChannelDefault', 'SpecialBlockbomb'),
  );
}

# =================================================================
#     write/remove pid file
# =================================================================

sub WritePid {
  my $file = PIDFILE;
  if ( open(OUT, "> $file") ) {
    print OUT $PID;
    close(OUT);
  } else {
    Report('error', undef, undef, "ERROR: Cannot open pid file `$file' to write");
    return undef;
  }
  return 1;
}

sub RemovePid {
  unlink PIDFILE;
}

# =================================================================
#     Shutdown functions
# =================================================================

sub StopServer {
  my ($relaunch) = @_;

  WriteBan();
  WriteProfile();
  WriteWinlist();
  WriteLmsg();
  WriteDaily( Time() );
  WriteLog("Server stopped");

  $Misc{listener}{tetrinet}->close();
  $Misc{listener}{lookup}->close() if defined $Misc{listener}{lookup};
  foreach (values %{$Misc{clients}}) {
    CloseSocket($_->{socket});
  }

  RemovePid();

  if ($relaunch) {
    exec(RELAUNCH) or Report('error', undef, undef, "ERROR: Cannot re-launch the server: $!");
  }
  exit 0;
}

sub IsServerStoppable {
  foreach my $ch (@Channels) {
    return undef if $ch->{ingame};
  }
  return 1;
}

sub SetShutdown {
  my ($relaunch) = @_;
  $Misc{shutdown} = {time => undef, relaunch => $relaunch};
}

sub CancelShutdown {
  $Misc{shutdown} = undef;
}

sub IsSetShutdown {
  return (defined $Misc{shutdown} ? 1 : undef);
}

sub CheckShutdown {
  return unless defined $Misc{shutdown};

  my $time = PTime();
  my $shutdown = $Misc{shutdown};
  if ( defined $shutdown->{time} ) {
    return unless $shutdown->{time} <= $time;
    my $relaunch = $shutdown->{relaunch};
    StopServer($relaunch);
  } else {
    if ( IsServerStoppable() ) {
      SendToAll('pline', 0, [Msg('ServerDownInNSeconds', SHUTDOWNWAITTIME)]) if SHUTDOWNWAITTIME > 0;
      $shutdown->{time} = $time + SHUTDOWNWAITTIME;
    }
  }
}

# =================================================================
#     Signal handlers
# =================================================================

sub SetSignalHandlers {
  if ($OSNAME ne 'MSWin32') {
    $SIG{CHLD} = \&SigChld;
    $SIG{HUP} = 'IGNORE';
    $SIG{INT} = \&SigInt;
  }
  $SIG{PIPE} = \&SigPipe;
  $SIG{TERM} = \&SigTerm;
  $SIG{__WARN__} = \&SigWARN;
}

sub SigChld {
  waitpid(-1, &POSIX::WNOHANG);

  # The following code seems to output "Server v0.20 in malloc(): warning:
  # recursive call." and "Out of memory!" errors and immediately die on FreeBSD.
  # According to some web site, the FreeBSD malloc() does not support SIG
  # handlers. So we don't use this commnly used code.

  # 1 while waitpid(-1, &POSIX::WNOHANG) > 0;
}

sub SigInt {
  StopServer(0);
}

sub SigPipe {
  $Misc{brokenpipe} = 1;
}

sub CheckBrokenpipe {
  my ($s) = @_;
  return unless defined $Misc{brokenpipe};

  Report('debug', undef, $s, "DEBUG: Broken pipe");
  $Misc{brokenpipe} = undef;
}

sub SigTerm {
  StopServer(0);
}

sub SigWARN {
  Report('debug', undef, undef, "DEBUG: " . join(', ', @_));
}

# =================================================================
#     Report functions
# =================================================================

sub Report {
  my ($type, $noreport, $lid, $msg) = @_;

  my $lmsg = LogID($lid) . $msg;

  if (not defined $Config) {
    WriteLog($lmsg);
    return;
  }

  my $key = ucfirst $type;
  $key =~ s/_(\w)/uc $1/eg;
  return if $key eq '';

  # log to file
  if ( GetReportConfigParam($key, 0) ) {
    WriteLog($lmsg);
  }

  # report to players
  my $perm = GetReportConfigParam($key, 1);
  return if $perm < 0;

  my $rmsg = $msg;
  $rmsg = StripColors($rmsg) if GetReportConfigParam('StripColors', 1) > 0;

  my @norep = ();
  if (defined $noreport) {
    @norep = ( (ref $noreport eq 'ARRAY') ? @$noreport : ($noreport) );
  }

  foreach my $player (values %Users) {
    next unless (defined $player and $player->{nick} ne '');
    my $user = $player->{socket};
    next if grep {$_ eq $user} @norep;
    Send($user, 'pline', 0, [Msg('Report', $rmsg)]) if CheckPermission($user, $perm);
  }
}

sub RMsgDisconnect {
  my ($reason, $s) = @_;

  my $nick;
  if (defined $Users{$s}) {
    $nick = ($Users{$s}{nick} ne '' ? $Users{$s}{nick} : "$Users{$s}{ip}/$Users{$s}{host}");
  } else {
    $nick = '';
  }

  return "Close Connection ($nick): $reason";
}

sub RMsgMove {
  my ($msg, $ch) = @_;

  my $chname = ChannelName($ch);

  my $slots = '';
  for (my $i=1; $i<=MAXPLAYERS; $i++) {
    my $user = $ch->{players}[$i] or next;
    my $nick = $Users{$user}{nick};
    $slots .= "$i.$nick ";
  }
  $slots =~ s/ $//;

  return "[$chname] $msg: $slots";
}

sub RMsgSet {
  my ($chname, $s, $key, $settings) = @_;

  my $nick = $Users{$s}{nick};
  $key = uc $key;

  return "[$chname] $nick changed channel settings $key to $settings";
}

sub LogID {
  my ($s) = @_;
  return '' unless defined $s;

  my $lid = "$s";
  ($lid) = ($lid =~ /\(0x([a-zA-Z0-9]+)\)$/);

  return ($lid ne '' ? "[$lid] " : '');
}

sub WriteLog {
  my ($msg) = join('', @_);
  return if $msg eq '';

  $msg =~ tr/\x0D\x0A//d; # strip crlf
  $msg = StripColors($msg) if GetReportConfigParam('StripColors', 0);

  my ($time_str, $sec, $min, $hour, $mday, $mon, $year) = LocalTime();

  my $file = LOGFILE;
  $file =~ s/%y/$year/g;
  $file =~ s/%m/$mon/g;
  $file =~ s/%d/$mday/g;

  open(OUT, ">> $file") or return; # how you can log this fail?
    print OUT "$time_str $msg\n";
  close(OUT);
}

sub GetReportConfigParam {
  my ($key, $no) = @_;

  return undef unless defined $Config;
  return -1 if ($no == 1 and $key =~ /^Raw/);

  my $value = $Config->val('Report', $key);
  $value = (split(/[^\+\-\d]+/, $value))[$no];

  if (defined $value and $value ne '') {
    return int($value);
  } else {
    return ($no == 1 ? -1 : 0);
  }
}

# =================================================================
#     Messages
# =================================================================

sub Send {
  my $s = shift;
  return unless defined $Users{$s};

  my @message = ();
  foreach (@_) {
    if (ref $_ eq 'ARRAY') {
      my @tmp = ();
      foreach my $member (@$_) {
        push(@tmp, (ref $member eq 'ARRAY' ? GetMsg($s, $member) : $member));
      }
      push(@message, join('', @tmp));
    } else {
      push(@message, $_);
    }
  }

  # ` ' is the parameter separator of the protocol
  my $msg = join(' ', @message);
  my $strip = TERMINATOR . QUERYTERMINATOR . "\x0D"; # 0xFF, 0x0A, 0x0D
  $msg =~ s/[$strip]//g; # strip terminators

  Report('raw_send', undef, $s, "Send: $msg");

  if ($Users{$s}{client} eq CLIENT_QUERY) {
    $msg .= QUERYTERMINATOR;
  } else {
    $msg .= TERMINATOR;
  }

  $Misc{writable}->add($s) if $Users{$s}{sendbuf} eq '';
  $Users{$s}{sendbuf} .= $msg;
}

sub SendToAll {
  my (@msg) = @_;

  foreach my $player (values %Users) {
    next unless (defined $player and $player->{nick} ne '');
    my $user = $player->{socket};
    Send($user, @msg);
  }
}

sub Msg {
  if (defined $Users{$_[0]}) {
    my ($s, @msg) = @_;
    return GetMsg($s, [@msg]);
  } else {
    return [@_];
  }
}

sub GetMsg {
  my ($s, $args) = @_;
  return '' unless defined $Users{$s};

  my ($name, @replaces) = @$args;
  my $msg = '';
  my $locale = (defined $Users{$s}{profile} ? $Users{$s}{profile}[PF_PLOCALE] : '');
  if (defined $Msg{$locale}) {
    $msg = $Msg{$locale}->val('Messages', $name);
  } else {
    my $default = lc $Config->val('Locale', 'Default');
    return '' unless defined $Msg{$default};
    $msg = $Msg{$default}->val('Messages', $name);
  }
  return '' if (not defined $msg or $msg eq '');

  $msg = ColorMsg($msg);

  for (my $i=@replaces; $i>0; $i--) {
    my $no = $i - 1;
    my $rep = (ref $replaces[$no] eq 'ARRAY' ? GetMsg($s, $replaces[$no]) : $replaces[$no]);
    $msg =~ s/%$no/$rep/g;
  }

  return $msg;
}

sub ColorMsg {
  my ($msg) = @_;

  for (my $i=0; $i<@COLOR_NAMES; $i++) {
    $msg =~ s/<$COLOR_NAMES[$i]>/$COLOR_CODES[$i]/g;
  }

  return $msg;
}

sub SendFromFile {
  my ($s, $file) = @_;

  $file = $Config->val('FilePath', lc $file);
  return undef if $file eq '';

  unless ( open(IN, "< $file") ) {
    Report('error', undef, undef, "ERROR: Cannot open file `$file' to read");
    return undef;
  }
  while (my $line = <IN>) {
    $line =~ tr/\x0D\x0A//d; # strip crlf
    Send($s, 'pline', 0, [ColorMsg($line)]);
  }
  close(IN);

  return 1;
}

# This code is from Java TetriNET Server (pihvi)'s code.
sub tnet_decrypt {
  my ($msg, $cmd) = @_;
  $cmd = HELLOMSG_TETRINET unless defined $cmd;

  my @dec;
  for (my $i=0; $i<length($msg); $i+=2) {
    push(@dec, hex substr($msg, $i, 2));
  }

  my @data = map {ord $_} split(//, $cmd);

  my @h;
  for (my $i=0; $i<@data; $i++) {
    push(@h, (($data[$i] + $dec[$i]) % 255) ^ $dec[$i + 1]);
  }
  my $h_length = 5;
  for (my $i=5; $i==$h_length and $i>0; $i--) {
    for (my $j=0; $j<@data-$h_length; $j++) {
      $h_length-- if $h[$j] != $h[$j + $h_length];
    }
  }

  return undef if $h_length == 0;

  my $decrypted = '';
  for (my $i=1; $i<@dec; $i++) {
    $decrypted .= chr((($dec[$i] ^ $h[($i - 1) % $h_length]) + 255 - $dec[$i - 1]) % 255);
  }

  my $zero = chr(0);
  my $replace = chr(255);
  $decrypted =~ s/$zero/$replace/g;

  return $decrypted;
}

sub StripCodes {
  my ($msg) = @_;
  $msg =~ tr/\x00\x09\x0A\x0D//d;
  return $msg;
}

sub StripColors {
  my ($msg) = @_;
  return '' if (not defined $msg or $msg eq '');

  foreach (@COLOR_CODES) {
    $msg =~ s/$_//g;
  }
  return $msg;
}

# =================================================================
#     Misc. functions
# =================================================================

sub CryptPassword {
  my ($pass) = @_;
  return '' if $pass eq '';

  my @set = ('a'..'z', 'A'..'Z', '0'..'9', '/', '.');
  my $salt = $set[rand @set] . $set[rand @set];

  my $crypted = crypt($pass, $salt);
  return $crypted;
}

sub CheckPassword {
  my ($input, $crypted) = @_;
  return undef if (not defined $input or $input eq '' or
                   not defined $crypted or $crypted eq '');

  if ( crypt($input, $crypted) eq $crypted ) {
    return 1;
  } else {
    return undef;
  }
}

sub ToInt {
  my ($value, $min, $max) = @_;

  $value = 0 if (not defined $value or $value eq '');
  $value = abs int $value;
  $value = $min if (defined $min and $value < $min);
  $value = $max if (defined $max and $value > $max);
  return $value;
}

sub LocalTime {
  my ($time) = @_;
  $time = Time() unless defined $time;

  my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($time);

  $year += 1900;
  $mon++;
  $mon = sprintf("%02d", $mon);
  $mday = sprintf("%02d", $mday);
  $hour = sprintf("%02d", $hour);
  $min = sprintf("%02d", $min);
  $sec = sprintf("%02d", $sec);

  my $time_str = "$year/$mon/$mday $hour:$min:$sec";

  return (wantarray ? ($time_str, $sec, $min, $hour, $mday, $mon, $year) : $time_str);
}

# source: http://www.din.or.jp/~ohzaki/perl.htm
sub round {
  my ($num, $decimals) = @_;
  my ($format, $magic);
  $format = '%.' . $decimals . 'f';
  $magic = ($num > 0) ? 0.5 : -0.5;
  sprintf($format, int(($num * (10 ** $decimals)) + $magic) /
                   (10 ** $decimals));
}

sub max {
  my ($a, $b) = @_;
  return ($a > $b ? $a : $b);
}
