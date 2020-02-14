#!/usr/bin/env perl

BEGIN {
    use File::Basename qw| dirname |;
    push @INC, dirname( __FILE__ );
}

use Data::Dumper;
use Term::ANSIColor;
use Test::More;

require_ok( "Mailbox.pm" );

my $Config = {
    'db_host' => '10.100.105.133',
    'db_user' => 'scriptuser',
    'db_pass' => 'scr1pt123',
    'db_name' => 'asterisk',
};

sub install_device_fx {
    my $ex = shift;
    my $mb = Mailbox->new( $ex, $Config );
    $mb->run_query( "INSERT INTO devices ( id, tech, dial, devicetype, user, description, emergency_cid ) VALUES ( '$ex', 'pjsip', 'PJSIP/$ex', 'fixed', '$ex', 'Some Description', '' )" ); 
}

sub install_users_fx {
    my $ex = shift;
    my $mb = Mailbox->new( $ex, $Config );
    $mb->run_query( "INSERT INTO users ( extension, name, voicemail, ringtimer, mohclass ) " .
        "VALUES ( '$ex', 'Name for $ex', 'guests', 0, 'default' )" );
}

sub install_sip_fx {
    my $ex = shift;
    my $sip_fixture = {
        'callerid' => $ex,
        'context'  => 'ci_cc',
        'mailbox'  => "$ex\@guests",
        'sipdriver' => 'chan_pjsip',
        'vmexten'   => $ex,
    };
    my $mb = Mailbox->new( $ex, $Config );
    while ( my ($k, $v) = each %$sip_fixture ) {
        $mb->run_query( "INSERT INTO sip ( id, keyword, data ) VALUES ( '$ex', '$k', '$v' )" );
    }   
}

sub remove_device_fx {
    my $ex = shift;
    my $mb = Mailbox->new( $ex, $Config );
    $mb->run_query( 'DELETE FROM devices WHERE id=?', $ex );
}

sub remove_users_fx {
    my $ex = shift;
    my $mb = Mailbox->new( $ex, $Config );
    $mb->run_query( 'DELETE FROM users WHERE extension=?', $ex );
}

sub remove_sip_fx {
    my $ex = shift;
    my $mb = Mailbox->new( $ex, $Config );
    $mb->run_query( 'DELETE FROM sip WHERE id=?', $ex );
}

sub doDump {
    my $ref = shift;
    print STDERR colored( "\n>>> doDump() DUMPING " . ref $ref, 'black on_yellow' );
    print STDERR Dumper $ref;
    print STDERR colored( "\n<<< END", 'black on_yellow' );
}

sub install_fixtures {
    my $ex = shift;
    print "Installing test fixtures....";
    install_device_fx( $ex );
    install_users_fx( $ex );
    install_sip_fx( $ex );
}

sub destroy_fixtures {
    my $ex = shift;
    print "Removing test fixtures....";
    remove_device_fx( $ex );
    remove_users_fx( $ex );
    remove_sip_fx( $ex )
}

#
# MAIN
#

my $E = '9999';
destroy_fixtures( $E );
install_fixtures( $E );

print "\n", colored( "OK! Starting tests!", 'bold green on_black' );

my $M = Mailbox->load( $E, $Config );
is ( ref $M, 'Mailbox', 'Got bless ( {...}, Mailbox )' );

diag( "Testing load and save..." );

destroy_fixtures( $E );
done_testing();

__END__

