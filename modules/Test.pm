# DaZeus - A highly functional IRC bot
# Copyright (C) 2011  Sjors Gielen <sjorsgielen@gmail.com>

package DaZeus2Module::Test;

use strict;
use warnings;

use base qw(DaZeus2Module);
use Data::Dumper;

sub told {
	my ($self) = @_;

	my @arrays = $self->store_keys();
        print "Number of keys in told(): " . scalar @arrays . "\n";
	print Dumper(@arrays);

	my $counter = $self->get("counter") || 0;
	++$counter;
	$self->set("counter", $counter);
	my $rand = int(rand(100));
	$self->set("counter".$counter, $rand);
	print "Counter: $counter\n";
	print "Counter$counter set to: $rand\n";
}

1;
