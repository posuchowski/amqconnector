#!/usr/bin/perl

use TAP::Harness;
use Cwd;
use File::Basename qw| dirname |;

my @tests = (
	[ 't/test_TiedMailbox.t', 'Test TiedMailbox' ],
	[ 't/load_and_save.t',    'Test Loading & Saving Extensions' ],
	[ 't/mailbox_getters.t',  'Test Mailbox Getter' ],
);

my $harness = TAP::Harness->new(
	{
		'lib' => [ dirname( Cwd::abs_path($0) ), ],
		'verbosity' => $ARGV[0] || 1,
		'color' => 1,
	}
);

$harness->runtests( @tests );

