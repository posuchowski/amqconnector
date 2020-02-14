#!/usr/bin/perl

#
# Pushes messages from STDIN onto ActiveMQ for testing receives.
#
package QPusher;

use strict;
use feature 'state';

use Net::Stomp;
use Data::Dumper;

$QPusher::Default = {
    q_ip    => "localhost",
    q_port  => "61613",
    q_login => "",
    q_pass  => "",
    send_q  => 'freepbxrequest',
    recv_q  => 'freepbxreceiver'
};

sub new {
    my ( $class, $config ) = @_;
    our $Default;
    bless {
        'Config' => $config || $Default,
    }, $class;
}

sub send_string {
    my ( $self, $body ) = @_;
    my $msg = {
        'destination' => "/queue/" . $self->{'Config'}->{send_q},
        'body'        => $body,
        'persistent'  => 'true',
    };
    $self->queue_connect()->send( $msg );
}

sub queue_connect {
    my $self = shift;

    state  $q = undef;
    return $q if defined $q;

    eval {
        local $SIG{__DIE__};
        $q = Net::Stomp->new(
            { hostname => $self->{'Config'}->{q_ip}, port => $self->{'Config'}->{q_port} }
        );
    };
    if( $@ ) {
        print STDERR "ERROR: Could not get Net::Stomp object: $@\n";
        return undef;
    }

    my $response = undef;
    eval {
        $response = $q->connect(
            { login => $self->{'Config'}->{q_login}, passcode => $self->{'Config'}->{q_pass} }
        );
    };
    if ( $@ ) {
        print STDERR "ERROR: Unable to connect. Error was: $@\n";
        return undef;
    }
    unless( defined $response ) {
        print STDERR "ERROR: Net::Stomp->connect returned undef.\n";
        return undef;
    }
    unless( $response->{command} eq 'CONNECTED' ) {
        print STDERR "ERROR: ActiveMQ broker failed to return 'CONNECTED'. Frame was:",
            Dumper( $response ), "\n";
        return undef;
    }

    print STDERR "Connected to ActiveMQ.\n";
    return $q;
}

#
# if __name__ == '__main__':
#
unless ( caller ) {
    my $Q = QPusher->new();
    while ( <> ) {
        $r = $Q->send_string( $_ );
        print "$r\n";
    }
    sleep 600;
}

