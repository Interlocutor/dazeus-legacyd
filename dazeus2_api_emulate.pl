#!/usr/bin/perl
use strict;
use warnings;
use DaZeus;
use DaZeus2Module;
use POE;

my ($socket, $network) = @ARGV;
if(!$network) {
	die "Usage: $0 socket network\n";
}

my $dazeus = DaZeus->connect($socket);
my $sock;
my $uniqueid = $network;

my $joined = 0;
foreach(@{$dazeus->networks()}) {
	if($_ eq $network) {
		$joined = 1;
		last;
	}
}
if(!$joined) {
	warn "Chosen network doesn't seem to be known in DaZeus...\n";
	warn "Known networks: " . join(', ', @{$dazeus->networks()}) . "\n";
	exit;
}

print "Getting config...\n";
my $numModules = $dazeus->getConfig("perlplugin.modules") || 0;
print "$numModules modules to load.\n";
my @modulesToLoad;
for(my $i = 1; $i <= $numModules; ++$i) {
	push @modulesToLoad, $dazeus->getConfig("perlplugin.module$i");
}
my @modules;

POE::Session->create(
	inline_states => {
		_start => \&start_legacyd,
		start  => \&start_legacyd,
		_stop  => sub { warn "Legacyd session stopping...\n" },
		sock   => \&sock_event,
		tick   => \&tick_event,
	},
);

POE::Kernel->run();

sub start_legacyd {
	print "Starting DaZeus 2 Legacy Plugin Daemon...\n";

	$dazeus->subscribe(qw/CONNECT DISCONNECT JOIN PART QUIT NICK
		MODE TOPIC INVITE KICK PRIVMSG NOTICE CTCPREQ CTCPREPL ACTION NUMERIC
		UNKNOWN NAMES WHOIS/, \&dazeus_event);

	foreach(@modulesToLoad) {
		print "Loading module $_....\n";
		reloadModule($_);
	}

	warn "Simulating a connection to network $network...\n";
	dazeus_event($dazeus, {event => "CONNECT", params => [$network]});
	my $channels = $dazeus->channels($network);
	my $mynick = $dazeus->getNick($network);
	foreach(@$channels) {
		warn "Simulating a join to channel $_...\n";
		dazeus_event($dazeus, {event => "JOINED", params => [$network, $mynick, $_]});
		$dazeus->sendNames($network, $_);
	}

	$_[KERNEL]->select_read($sock = $dazeus->socket(), "sock");
	$_[KERNEL]->delay(tick => 5);
	$dazeus->handleEvents();
}

sub tick_event {
	dispatch( "tick" );
	$_[KERNEL]->delay(tick => 5);
}

sub dazeus_event {
	my (undef, $event) = @_;
	my @p = @{$event->{params}};
	if(shift(@p) ne $network) {
		# Ignore event not happening on this network
		return;
	}
	my $e = uc($event->{event});
	if($e eq "WHOIS") {
		whois($uniqueid, $p[1], $p[2] eq "true" ? 1 : 0);
	} elsif($e eq "PRIVMSG") {
		message($uniqueid, $p[0], $p[1], $p[2], $p[2]);
	} elsif($e eq "JOIN") {
		dispatch( "chanjoin", undef, undef, {
			who => $p[0],
			channel => $p[1],
		});
	} elsif($e eq "PART") {
		dispatch("chanpart", undef, undef, {
			who => $p[0],
			channel => $p[1],
		});
	} elsif($e eq "NICK") {
		dispatch( "nick_change", 0, 0, $p[0], $p[1] );
	} elsif($e eq "CONNECT") {
		dispatch( "connected" );
	} elsif($e eq "NAMES") {
		shift @p;
		my $chan = shift @p;
		namesReceived($uniqueid, $chan, join(' ', @p));
	}
}

sub sock_event {
	my ($handle, $mode) = @_[ARG0, ARG1];
	eval {
		$dazeus->handleEvents();
	};
	if($@) {
		warn "Handling events failed: $@\n";
		warn "Attempting to restart session...\n";
		$_[KERNEL]->select_read($sock);
		undef $sock;
		do {
			warn "Attempting to connect...\n";
			eval {
				$dazeus = DaZeus->connect($socket);
			};
			if($@ || !$dazeus) {
				warn "Attempt failed: $@\n";
				undef $dazeus;
				sleep 5;
			}
		} until($dazeus);
		warn "Connected. Restarting session...\n";
		$_[KERNEL]->delay(start => 1);
	}
}

sub whois {
  $uniqueid = shift;
  my ($nick, $is_identified) = @_;
  my $whois = {
    nick => $nick,
    identified => $is_identified,
  };

  for my $mod (@modules)
  {
    eval { $mod->whois($whois); };
    if( $@ )
    {
      warn("Error executing $mod ->whois(): $@\n" );
      next;
    }
  }
}

sub message {
  $uniqueid = shift;
  my ($sender, $receiver, $body, $raw_body) = @_;
  my $mess = {
    channel => ($receiver =~ /^(#|&)/) ? $receiver : "msg",
    body    => $body,
    raw_body => $raw_body,
    who     => $sender,
  };

  __said($mess);
}

sub __said {
  my ($mess) = @_;

  for my $pri (0..3)
  {
    dispatch( "said",
      sub {
        my ($error, $mod, $args) = @_;
        my $mess = $args->[0];
        $mod->reply($mess, "Error executing $mod ->said(): $error\n");
      },
      sub {
        my ($message, $mod, $args) = @_;
        my $mess    = $args->[0];
        if( $message && $message ne "1" && !ref($message) )
        {
          $mod->reply($mess, $message);
          return -1;
        }
      }, $mess, $pri );
  }

  return;
}

sub dispatch {
  my $method = shift;
  my $error_callback   = shift || sub {};
  my $message_callback = shift || sub {};

  for my $mod (@modules)
  {
    my $message;
    eval { $message = $mod->$method( @_ ); };
    if( $@ )
    {
      warn("Error executing $mod -> $method: $@\n" );
      my $result = $error_callback->($@, $mod, \@_);
      return if( $result && $result eq "-1" );
      next;
    }
    my $result = $message_callback->($message, $mod, \@_);
    return if( $result && $result eq "-1" );
  }
}

sub getModule {
  foreach(@modules)
  {
    if( $_->{Name} eq $_[0])
    {
      return $_;
    }
  }
  return undef;
}

sub namesReceived {
  $uniqueid = shift;
  my ($channel, $names ) = @_;
  my %names;
  foreach( split /\s+/, $names )
  {
    my $op = /^\+?@/;
    my $voice = /^@?\+/;
    s/^[\+@]+//;
    $names{$_} = {op => $op, voice => $voice};
  }

  dispatch( "got_names", 0, 0, {
    channel => $channel,
    names   => \%names,
  } );
}

sub reloadModule {
  my $oldmod = getModule($_[0]);
  unloadModule($_[0]) if($oldmod);
  loadModule($_[0]);
  my $newmod = getModule($_[0]);
  $newmod->reload($oldmod);
  return $newmod;
}

sub unloadModule {
  my $to_remove = $_[0];
  my $module = getModule($to_remove);
  return 1 if(!$module);
  @modules = grep { $_->{Name} ne $to_remove } @modules;
}

sub loadModule {
  my $module = $_[0] if(@_ == 1);
  ($uniqueid, $module) = @_ if(@_ > 1);

  return 1 if getModule($module);

  my $file = "./modules/$module.pm";

  if( ! -e $file )
  {
    warn "Could not find $file\n";
    return 0;
  }

  # force a reload of the file
  no warnings 'redefine';
  delete $INC{$file};
  require $file;

  $module = "DaZeus2Module::$module";

  push @modules, $module->new( DaZeus => $dazeus, Network => $network );
  return 1;
}

1;
