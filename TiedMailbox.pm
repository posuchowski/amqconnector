use strict;
use warnings;
use utf8;

package TiedMailbox;

use DBI;
use Carp qw| confess croak |;  # TiedMailbox is purposely fragile

our @db_tables = (
    'vm_options',
    'sip',
    'users',
    'devices',
);

our $field_tables = {
    ( map { $_ => 'sip' } (
        'account',
        'callerid',
        'context',
        'mailbox',
        'sipdriver',
        'vmexten'
    )),
    ( map { $_ => 'devices' } (
        'tech',
        'dial',
        'devicetype',
        'user',
        'description',
        'emergency_cid'
    )),
    ( map { $_ => 'users' } (
        'extension',
        'password',
        'name',
        'voicemail',
        'sipname',
        'ringtimer',
        'mohclass'
    )),
};

sub run_query {
    my ( $self, $query, @data ) = @_;
    my ( $dbh, $sth, $res, @rset );

    confess "FATAL: Failed to to connect to mysql: $DBI::errstr" 
        unless $dbh = DBI->connect(
				sprintf( "DBI:mysql:%s:%s", $self->{db_creds}->{'db_name'}, $self->{db_creds}->{'db_host'} ),
				$self->{db_creds}->{db_user},
				$self->{db_creds}->{db_pass}
        );
    confess "FATAL: Statement handle is False."
        unless $sth = $dbh->prepare( $query ); 
    confess "FATAL: Failed to execute prepared statement. Errstr was: $DBI::errstr\n"
        unless $res = $sth->execute( @data );

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
    return wantarray ? @rset : shift @rset;
}

sub mbox_exists {
    my ( $self, $id ) = @_;
    my $box = $self->run_query(
        qq[ SELECT count( id ) FROM devices WHERE id = $id ]
    );
    return 1 if ( $box->[0] > 0 );
    return 0;
}

sub whichTable {
    my ( $self, $key ) = @_;
    our $field_tables;
    return $field_tables->{$key};
}

sub save_sip {
    my ( $self, $key, $value ) = @_;
    my $query = 'UPDATE sip SET data = ? WHERE id = ? AND keyword = ?';
    return $self->run_query( $query, $value, $self->{id}, $key );
}

sub get_sip {
    my ( $self, $key ) = @_;
    my $query = 'SELECT data FROM sip WHERE id = ? AND keyword = ?';
    my $res   = $self->run_query( $query, $self->{id}, $key );
    return $res->[0];
}

sub save_devices {
    my ( $self, $key, $value ) = @_;
    my $query = "UPDATE devices SET $key = ? WHERE id = ?";
    return $self->run_query( $query, $value, $self->{id} );
}

sub get_devices {
    my ( $self, $key ) = @_;
    my $query = "SELECT $key FROM devices WHERE id = ?";
    my $res   = $self->run_query( $query, $self->{id} );
    return $res->[0];
}

sub save_users {
    my ( $self, $key, $value ) = @_;
    my $query = "UPDATE users SET $key = ? WHERE extension = ?";
    return $self->run_query( $query, $value, $self->{id} );
}

sub get_users {
    my ( $self, $key ) = @_;
    my $query = "SELECT $key FROM users WHERE extension = ?";
    my $res   = $self->run_query( $query, $self->{id} );
    return $res->[0];
}

sub save_vm_options {
    my $self = shift;
    confess "save_vm_options() is UNIMPLEMENTED yet";
}

sub TIEHASH {
    my ( $class, $id, $creds ) = @_;
    my $self = {
        'id'         => $id,
        'db_creds'   => $creds,
    };
    $self->{ $_ } = {} foreach @TiedMailbox::db_tables;
    bless $self, $class;
    confess "Mailbox does not exist" unless $self->mbox_exists( $id );
    return $self;
}

sub FETCH {
    my ( $self, $key ) = @_;
    return $self->{id} if $key eq 'id';
    if ( my $table = $self->whichTable( $key ) ) {
        no strict 'refs';
        my $method = "get_$table";
        return $self->$method( $key );
    }
    return undef;
}

sub STORE {
    my ( $self, $key, $value ) = @_;
    if ( $key eq 'id' ) {
        return $self->{id} = $value;
    }
    if ( my $table = $self->whichTable( $key ) ) {
        no strict 'refs';
        my $method = "save_$table";
        return $self->$method( $key, $value );
    }
    return undef;
}

sub EXISTS {
    my ( $self, $key ) = @_;
    return exists $self->{id} if $key eq 'id';
    if ( my $table = $self->whichTable( $key ) ) {
        return 1 if $self->FETCH( $key );
    }
    return 0;
}

# N/A to our situation
sub DELETE   { return 0;     }
sub CLEAR    { return 1;     }
sub FIRSTKEY { return undef; }
sub NEXTKEY  { return undef; }

1;

