#!/usr/bin/env perl

use lib '.';
use Test::More;
use Try::Tiny;
use DBI;
use Data::Dumper;

use TiedMailbox;

my $testbox = '99001';

my $DB = {
    'db_host' => 'localhost',
    'db_user' => 'wclient',
    'db_pass' => '1234567',
    'db_name' => 'asterisk'
};

sub runner {
    my ( $query, @data ) = @_;
    # print STDERR "test_TiedMailbox.runner(): $query\n";
    die "Test query runner failed to connect to MySQL/MariaDB"
        unless $dbh = DBI->connect(
				sprintf( "DBI:mysql:%s:%s", $DB->{'db_name'}, $DB->{'db_host'} ),
				$DB->{db_user},
				$DB->{db_pass}
        );
    die "FATAL: Statement handle is False."
        unless $sth = $dbh->prepare( $query ); 

    if ( $query =~ /[?]/ ) {
        die "FATAL: Failed to execute prepared statement. Errstr was: $DBI::errstr\n"
            unless $res = $sth->execute( @data );
    }
    else {
        die "FATAL: Failed to execute prepared statement. Errstr was: $DBI::errstr\n"
            unless $res = $sth->execute();
    }

    if ( $sth->{NUM_OF_FIELDS} ) {
        while ( my @a = $sth->fetchrow_array ) {
            push @rset, \@a;
        }
        warn $sth->err if $sth->err;
    }
    else {
        warn $sth->err if $sth->err;
        push @rset, undef;
    }
    $sth->finish if $sth->{Active};
    $dbh->disconnect();
    return 1 if $query =~ /INSERT/ or $query =~ /DELETE/;
    return wantarray ? @rset : shift @rset;
}

# Just in case
ok ( runner( "DELETE FROM devices WHERE id = $testbox" ), '(cleanup)' );
ok ( runner( "DELETE FROM users WHERE extension = $testbox" ), '(cleanup)' );
ok ( runner( "DELETE FROM sip WHERE id = $testbox" ), '(cleanup)' );

#
# Start
#
my $MBox = try { tie ( my %dne, 'TiedMailbox', $testbox, $DB ); };
isnt ( ref $Mbox, 'TiedMailbox', 'Tieing hash to nonexistent extension failed -- good' );

#
# Test instantiation and setting
#
ok ( runner( "INSERT INTO devices ( id, tech, dial, devicetype, user, description, emergency_cid ) VALUES ( '99001', 'sip', 'SIP/99001', 'fixed', '99001', 'TestDesc', '' )" ), '(test fixture)' );
ok ( runner( "INSERT INTO users ( extension, password, name, voicemail, sipname ) VALUES ( '99001', '111', 'TestName', 'novm', '99001' )" ), '(test fixture)' );
ok ( runner( "INSERT INTO sip ( id, keyword, data ) VALUES ( '99001', 'mailbox', '99001' )" ), '(test fixture)' );
note( 'Installed database fixtures for test extension 99001' );

$MBox = tie ( my %mailbox, 'TiedMailbox', $testbox, $DB );
is ( ref $MBox, 'TiedMailbox', 'Tieing hash to existing mailbox worked -- also good' );

#
# Test loading
#
is ( $mailbox{'devicetype'}, 'fixed', 'Loaded from asterisk.devices OK' );
is ( $mailbox{'password'}, '111', 'Loaded from asterisk.users OK' );
is ( $mailbox{'mailbox'}, '99001', 'Loaded from asterisk.sip OK' );

#
# Test saving 
#

$mailbox{'mailbox'} = $testbox;
is ( $mailbox{'mailbox'}, $testbox, 'Setting something using save_sip() seems to work.' );

$mailbox{'tech'} = 'pjsip';
is ( $mailbox{'tech'}, 'pjsip', 'Setting something using save_devices() seems to work.' );

$mailbox{'voicemail'} = 'novm';
is ( $mailbox{'voicemail'}, 'novm', 'Setting something using save_users() seems to work.' );

$mailbox{'voicemail'} = 'default';
is ( $mailbox{'voicemail'}, 'default', 'And again' );

#
# Clean up
#
done_testing();
__END__

ok ( runner( 'DELETE FROM devices WHERE id = 99001' ) );
ok ( runner( 'DELETE FROM users WHERE extension = 99001' ) );
ok ( runner( 'DELETE FROM sip WHERE id = 99001' ) );
note( 'Removed database fixtures.' );

done_testing();

