#!/usr/bin/perl -w

use strict;
use feature qw| state |;
use less    qw| fat   |;

use Carp qw| shortmess longmess |;
use DBI;
use Data::Dumper;
use Net::Stomp;
use TiedMailbox;
use Time::HiRes qw| gettimeofday tv_interval sleep |;

use constant LOG_ALWAYS => 1;   # Messages not affected by mask
use constant LOG_ERROR => 2;
use constant LOG_WARNING => 4;  # From sub handle_warn()
use constant LOG_ACTION => 8;   # Actions taken (updates, swaps, etc)
use constant LOG_PROGRAM => 16; # Program activity
use constant LOG_MESSAGE => 32; # Incoming/outgoing messages
use constant LOG_DEBUG => 64; 
use constant LOG_FLOW => 128;   # Program flow
use constant LOG_ALL => 255;

# For general use this is pretty good:
use constant LOG_USEFUL => LOG_ERROR + LOG_ACTION;

# Defaults. Use /etc/amqconnector.conf to alter.
my $Defaults = {
    logfile => "/var/log/amqconnector.log",
    loglevel => LOG_USEFUL,
    service_check_interval => 10,       # seconds between periodic service
                                        #   check and queue reconnect attempts
    max_per_second => 10,               # roughly throttle msg processing
    db_host => "localhost",
    db_user => "percipia",
    db_pass => "percipia123",
    db_name => "asterisk",
    q_ip    => "localhost",
    q_port  => "61613",
    q_login => "",
    q_pass  => "",
};

# Before SIG handling
our $Config = read_config( '/etc/amqconnector.conf', $Defaults );
writelog( LOG_PROGRAM,
    "Starting with the following configuration:", Dumper( $Config )
);

$SIG{__DIE__}  = \&handle_die;
$SIG{__WARN__} = \&handle_warn;
$SIG{INT}      = \&handle_int;
$SIG{TERM}     = \&handle_term;

die ( "Another instance of amqconnector is already running.\n" )
    if ( already_running() );
writelog( LOG_ALWAYS, "Started amqconnector" );

while ( 1 ) {
    writelog( LOG_FLOW, "Started outer while loop. Checking services first..." );
    ensure_activemq();
    ensure_freepbx();

    writelog( LOG_FLOW, "Getting queue objects..." );
    my $ReadQ = queue_connect();
    my $SendQ = queue_connect();

    unless ( defined $ReadQ and defined $SendQ ) {
        writelog( LOG_ERROR, "ERROR: Problem connecting to ActiveMQ. Sleeping " .
            $Config->{service_check_interval} . " and retrying..."
        );
        sleep $Config->{service_check_interval};
        next;
    }

    $ReadQ->subscribe(
          {   destination             => '/queue/freepbxrequest',
              'ack'                   => 'client',
              'activemq.prefetchSize' => 1
          }
    );
    writelog( LOG_PROGRAM, "ReadQ subscribed to receive on /queue/freepbxrequest" );

    while ( 1 ) {
        writelog( LOG_FLOW, "Entered inner while. Calling Net::Stomp->receive_frame..." );
        my $frame;

        eval {
            # override to catch error below instead of invoking the handler
            local $SIG{__DIE__};  
            local $SIG{ALRM} = sub { die "SIGALRM\n" };
            alarm $Config->{service_check_interval};
            # timeout defaults to undef=forever
            # but if activemq broker goes down, it could die
            $frame = $ReadQ->receive_frame;  
            alarm 0;
        };
        if ( $@ ) {
            if ( $@ =~ /SIGALRM/ ) {
                writelog( LOG_FLOW, "Waking up to recheck services." );
            }
            else {
                writelog( LOG_ERROR, "ERROR: Connection problem: call to receive_frame died with message:\n$@" );
            }
            last;
        }
        unless ( defined $frame ) {
            writelog( LOG_ERROR,
                "ERROR: Connection problem: Got undef from receive_frame.",
                "Attempting to reconnect."
            );
            last;
        }

        writelog( LOG_MESSAGE, "------------NEW MESSAGE-----------" );

        my $start_time = [ gettimeofday() ];
        my @message  = split( "~", $frame->body );
        my $msg_id   = shift @message;
        my $msg_type = shift @message;

        writelog( LOG_MESSAGE, "Received message type '$msg_type'" );
        writelog( LOG_DEBUG, Dumper( $msg_id, $msg_type, @message ) );

        if ( $msg_type eq "apply_changes" ) {
            # Hospitality component will message to reload the page to apply changes.
            # (The JavaScript onClick just reloads a DIV.)
            $SendQ->send( do_apply_changes( $msg_id ) );
        }
        elsif ( $msg_type eq "ext_update" ) {
            $SendQ->send(
                do_ext_update( $msg_id, $msg_type, @message )
            );
        }
        elsif ( $msg_type eq "mbox_update" ) {
            $SendQ->send(
                do_mbox_update( $msg_id, @message )
            )
        }
        elsif ( $msg_type eq "swap_mbox" ) {
            $SendQ->send(
                do_swap_mbox( $msg_id, @message )
            )
        }
        else {
            my $msg = {
                'destination' => '/queue/freepbxreceiver ',
                'body' => $msg_id . '~failure~Bad Message Type',
                'persistent' => 'true'
            };
            $SendQ->send($msg);
            writelog( LOG_MESSAGE, "Sent failure message:\n" . Dumper($msg) );
        }
        $ReadQ->ack( { frame => $frame } );
        writelog( LOG_MESSAGE, "---------- SENT ACK ----------" ); 

        # Apply throttle
        my $goal_t  = 1 / $Config->{max_per_second};
        my $elapsed = tv_interval( $start_time );
        sleep( $goal_t - $elapsed - 0.01 ) if $elapsed < $goal_t;
    }
    writelog( LOG_FLOW, "Exited inner while." );
}
writelog( LOG_FLOW, "OOPS! Exited main while loop." );

#
# Subroutines
#

sub do_ext_update {
	our $Config;
    my ( $msg_id, $msg_type, @message ) = @_;

    writelog( main::LOG_MESSAGE, "do_ext_update(): Our \@message=\n" . Dumper( @message ) );

    my $ext = (split( "=", $message[0] ))[1];
    my $primary_ext = (split( "=", $message[1] ))[1];

    my $cid_name = (split( "=", $message[2] ))[1];
    $cid_name =~ s/[^0-9| |A-Z|a-z|-]//g if defined $cid_name;

    my $call_perm   = (split( "=", $message[3] ))[1];
    my $ext_dial    = (split( "=", $message[4] ))[1];
    my $update_type = (split( "=", $message[5] ))[1];

    eval {
        my $object = tie ( my %mailbox, 'TiedMailbox', $Config );
    };
    if ( defined $@ and length $@ ) {
        my $msg = {
            'destination' => '/queue/freepbxreceiver',
            'body' => "$msg_id~failure~EXTENSION $ext does not exist",
            'persistent' => 'true'
        };
        writelog( main::LOG_ERROR, "ERROR: Requested extension '$ext' Does not exist." );
        writelog( main::LOG_MESSAGE, "Returning failure message: \n" . Dumper( $msg ) ); 
        return $msg;
    } 

    writelog( main::LOG_FLOW, "do_ext_update(): Loaded mailbox for extension $ext." );

    if ( $update_type eq "pbxinfo" ) {
        $mailbox{'context'} = $call_perm             if ( $call_perm and $call_perm ne "null" );
        $mailbox{'mailbox'} = "$primary_ext\@guests" if $primary_ext;
        $mailbox{'name'}    = $cid_name              if $cid_name;
    }
    else {
      if ( $ext_dial and $primary_ext ) {
        $mailbox{'dial'}    = $ext_dial;
        $mailbox{'mailbox'} = "$primary_ext\@guests";
      } 
      else {
        my $msg = {
            'destination' => '/queue/freepbxreceiver',
            'body' => qq|$msg_id~failure~Missing arguments for $msg_type - $update_type|,
            'persistent' => 'true'
        };
        writelog( main::LOG_ERROR, "ERROR: Failed to update extension $ext:",
             "Missing arguments in pbxinfo update message." );
        writelog( main::LOG_MESSAGE, "Sent failure message:" . Dumper($msg) );
        return $msg;
      }
    }

    my $msg = {
        'destination' => '/queue/freepbxreceiver',
        'body' => "$msg_id~success",
        'persistent' => 'true'
    };
    writelog( main::LOG_ACTION, "Updated extension '$ext' (primary = '$primary_ext')" );
    writelog( main::LOG_MESSAGE, "Sent success message:\n" . Dumper($msg) );
    return $msg;
}

sub do_mbox_update {
	our $Config;
	our $VMSettings;
    my ( $msg_id, @message ) = @_;

    writelog( main::LOG_FLOW, "do_mbox_update: \@message=\n" . Dumper( @message ) );

    my $ext = (split( "=", $message[0] ))[1];
    my $mbox_status  = (split( "=", $message[1] ))[1];
    my $mbox_pass    = (split( "=", $message[2] ))[1];
    my $mbox_context = (split( "=", $message[3] ))[1];

    eval {
        my $object = tie ( my %mailbox, 'TiedMailbox', $Config );
    }
    if ( defined $@ and length $@ ) {
        my $msg = {
            'destination' => '/queue/freepbxreceiver',
            'body' => "$msg_id~failure~MAILBOX $ext does not exist",
            'persistent' => 'true'
        };
        writelog( main::LOG_ERROR, "ERROR: Failed to update mailbox for extension $ext: Does not exist." );
        writelog( main::LOG_MESSAGE, "Sent failure message:\n" . Dumper($msg) );
        return $msg;
    }

    $mailbox{'password'}  = $mbox_pass;
    $mailbox{'context' }  = $mbox_context;
    $mailbox{'voicemail'} = ( $mbox_status eq 'on' ) ? $mbox_context : 'novm';

    my $msg =  {
        'destination' => '/queue/freepbxreceiver',
        'body' => "$msg_id~success",
        'persistent' => 'true'
    };
    writelog( main::LOG_ACTION, "Updated mailbox for extention '$ext'" );
    writelog( main::LOG_MESSAGE, "Returning success message:\n" . Dumper($msg) );
    return $msg;
}

sub do_swap_mbox {
	our $Config;
    my ( $msg_id, @message ) = @_;
    my ( @forms, %fields );
    } = undef;
    my $saved = {};

    writelog( main::LOG_DEBUG, "do_swap_mbox: Reveived \@message =\n" . Dumper( @message ) );

    my @extension = (
        (split( "=", $message[0] ))[1],
        (split( "=", $message[1] ))[1]
    );
    my @vm_passwd = (
        (split( "=", $message[2] ))[1],
        (split( "=", $message[3] ))[1]
    );

    # Get web forms for both extensions or abort the swap
    foreach my $e( @extension ) {
        unless ( extension_exists( $e ) ) {
            my $msg = {
                  'destination' => '/queue/freepbxreceiver ',
                  'body' => $msg_id . '~failure~MAILBOX ' . $e . ' does not exist',
                  'persistent' => 'true'
            };
            writelog( main::LOG_ERROR,
                "ERROR: Failed to swap mailboxes for extensions " 
              . $extension[0] . " and " . $extension[1]
              . ": Extension $e does not exist."
            );
            writelog( main::LOG_MESSAGE, "Returning error message: $msg" );
            return $msg;
        }
        if ( my $f = get_extension_form( $e ) ) {
            push @forms, $f;
        }
        else {
            writelog( main::LOG_ERROR, "ERROR: Aborting swap: No form for extension '$e'" );
            return;
        }
    }

    # Perform the swap...
    $saved->{$_} = $forms[0]->value($_) foreach ( keys %fields );

    # ...but if the vm password == the value passed in activeMQ, use that instead.
    # This retains the default setting, most likely to the extension number,
    # unless it's been altered by the guest.
    if ( $forms[0]->value( 'vmpwd' ) eq $vm_passwd[0] ) {
        # ^ '0123' ne '123'
        $saved->{'vmpwd'} = $vm_passwd[1];
    }

    $forms[0]->value( $_, $forms[1]->value( $_ ) ) foreach ( keys %fields );
    if ( $forms[1]->value( 'vmpwd' ) eq $vm_passwd[1] ) {
        $forms[0]->value( 'vmpwd', $vm_passwd[0] );
    }

    $forms[1]->value( $_, $saved->{$_} ) foreach ( keys %fields );

    # Make sure our form fields are enabled if vm is enabled.
    foreach my $form( @forms ) {
        if ( $form->value( 'vm' ) eq 'enabled' ) {
            writelog( main::LOG_DEBUG, "Reenabling inputs on form named '" . $form->value( 'name' ) );
            $form->find_input( $_ )->disabled( 0 ) foreach ( keys %fields );
        }
        $form->find_input( 'vm' )->disabled( 0 );
    }

    # To dump a text repr of the forms, use:
    # writelog( main::LOG_DEBUG, $_->dump ) foreach @forms;

    get_browser()->request( $_->click('Submit') ) foreach @forms;
    my $msg = {
        'destination' => '/queue/freepbxreceiver ',
        'body'=> $msg_id . '~success',
        'persistent' => 'true'
    };
    writelog( main::LOG_ACTION, "Swapped mailboxes for extensions " . $extension[0] . " and " . $extension[1] );
    writelog( main::LOG_MESSAGE, "Returning success message:\n" . Dumper( $msg ) );
    return $msg;
}


sub read_config {
	our $Config;
    my $file = shift;
    my $defaults = shift;
    my $c = {};

    open( FD, "$file" ) or die "$!\n";
    foreach my $l( <FD> ) {
        next unless $l =~ /\w/;
   
        $l =~ s/#.*//;

        my @p = split( '=', $l );
        chomp foreach @p;
        $p[0] =~ s/\s//g;
        $p[1] =~ s/\s//g;

        # Evaluate constants defined in this script...
        if ( $p[1] =~ /LOG_/ ) {
            # ...but prevent execution of arbitrary code via:
            # log_level = LOG_ERROR; print( "pwned!\n" );
            if ( $p[1] =~ /[^A-Z0-9_+-]/ ) {
                print STDERR "Invalid log_level value: " . $p[1] . "\n";
                exit 1;
            }
            eval {
                $p[1] = eval "$p[1]";  # Famous Last Words
            };
            if ( $@ ) {
                print STDERR "Failed to evaluate log_level value: " . $p[1] . "\n";
                exit 2;
            }
        }            
        $c->{ $p[0] } = $p[1];
    }
    close FD;

    # Apply defaults
    $c->{$_} //= $defaults->{$_} foreach keys %{$defaults};
    # Reject unknown keys
    foreach my $k( keys %{$c} ) {
        next if exists $defaults->{$k};
        print STDERR "Unknown configuration key: '$k' in $file\n";
        exit 3;
    }
    return $c;
}

sub handle_die {
    writelog( LOG_ALWAYS,
        "HANDLE_DIE: script caught unhandled die() with error: ", shortmess(),
        "STACK TRACE:", longmess()
    );
}

sub handle_warn {
    writelog( LOG_WARNING, "WARNING: " . shortmess() );
}

sub handle_int {
    writelog( LOG_ALWAYS, "handle_int: Exiting on SIGINT. Bye." );
    exit( 0 );
}

sub handle_term {
    writelog( LOG_ALWAYS, "handle_term: Exiting on SIGTERM. Bye." );
    exit( 0 );
}

sub already_running {
	our $Config;
    my $name = $0;
    $name =~ s|.*/||;
    my @x = `ps -C $name -o pid=`;
    return 1 if ( @x > 1 );
    return 0;
}

sub ensure_activemq {
	our $Config;
    my $running = `pgrep activemq`;
    while ( not $running ) {
        writelog( LOG_ERROR, "ERROR: ActiveMQ not running. Trying to restart..." );
        system( 'service', 'activemq', 'start', '1>/dev/null', '2>&1' );
        sleep 3;
        if ( $running = `pgrep activemq` ) {
            writelog( LOG_ERROR, "Restarted ActiveMQ service." );
        }
    }
    writelog( LOG_FLOW, "Checked: ActiveMQ is running." );
}

sub ensure_freepbx {
	our $Config;
    my $ps_count = `ps -C java -o cmd | grep freepbx | wc -l`;
    while ( $ps_count < 2 ) {
        writelog( LOG_ERROR, "ERROR: FreePBX-based software not running. Trying to restart..." );
        ensure_activemq(); # don't get trapped in here
        system( 'service', 'freepbx', 'start', '1>/dev/null', '2>&1' );
        sleep 3;
        if ( $ps_count = `ps -C java -o cmd | grep freepbx | wc -l` ) {
            writelog( LOG_ERROR, "Restarted FreePBX-based software service." );
        }
    }
    writelog( LOG_FLOW, "Checked: FreePBX is running." );
}

sub writelog {
	our $Config;
    my ( $level, @msg ) = @_;
    return unless ( $Config->{loglevel} & $level ) || ( $level & LOG_ALWAYS ) ;
    open( FD, ">>" . $Config->{logfile} ) or die "$!\n";
    foreach my $l (@msg) {
        chomp $l;
        print FD (localtime time) . ": " . $l . "\n";
    }
    close FD;
}

sub extension_exists {
	our $Config;
    my $e = shift;
    my $url = 'http://' 
            . $Config->{freepbx_ip}
            . '/admin/config.php?display=extensions&username=scriptclient&password=scr1ptp4ss'; 
    my $response = get_browser()->get( $url );
    unless ( $response->is_success ) {
        writelog( LOG_ERROR, "ERROR: Failed to GET list of extensions from freepbx admin." );
        writelog( LOG_DEBUG, "\$response->status_line = " . $response->status_line,
            "\$url = '$url'" );
        return;
    }
    if ( $response->content =~ /extdisplay=$e/ ) {
        writelog( LOG_DEBUG, "extension_exists(): Found match for '$e', returning 1" );
        return 1;
    }
    else {
        writelog( LOG_DEBUG, "extension_exists() returning undef for '$e'" );
    }
    return undef;  # Don't implicitly return last expression
}

sub get_extension_form {
	our $Config;
    my $e = shift;
    my $response = get_http_response(
        'http://' . $Config->{freepbx_ip} .
        "/admin/config.php?display=extensions&username=scriptclient&password=scr1ptp4ss&extdisplay=$e"
    );
    my $form;
    eval {
        $form = HTML::Form->parse( $response->decoded_content, $response->base );
    };
    if ( $@ ) {
        writelog( LOG_ERROR, "ERROR: call to HTML::Form->parse() failed with:", $@ );
        return;
    }
    return $form;
    writelog( LOG_FLOW, "Retrieved web form for extension $e" );
}

sub get_http_response {
	our $Config;
    my $url = shift;
    my $response = get_browser()->get( $url );
    unless ( $response->is_success ) {
        writelog( LOG_ERROR, "ERROR: Get of url '$url' failed. Status was:",
            $response->status_line );
        return;
    }
    return $response;
}

sub queue_connect {
	our $Config;
    my $q;
    state $q_count = 0;

    eval {
        local $SIG{__DIE__};
        $q = Net::Stomp->new(
            { hostname => $Config->{q_ip}, port => $Config->{q_port} }
        );
    };
    if ( $@ ) {
        writelog( LOG_ERROR, "ERROR: Could not get Net::Stomp object: $@" );
        return undef;
    }

    my $response = $q->connect(
        { login => $Config->{q_login}, passcode => $Config->{q_pass} }
    );
    unless ( defined $response ) {
        writelog( LOG_ERROR, "ERROR: Net::Stomp->connect returned undef." );
        return undef;
    }
    unless ( $response->{command} eq 'CONNECTED' ) {
        writelog( LOG_ERROR,
            "ERROR: ActiveMQ broker failed to return 'CONNECTED'. Frame was:",
            Dumper( $response )
        );
        return undef;
    }
    writelog( LOG_PROGRAM,
        "Connected to ActiveMQ " .
        ( ++$q_count % 2 == 1 ? "once to read." : "twice to send." )
    );
    return $q;
}

sub do_apply_changes {
    my $self = shift;
    my $msg_id = shift;
    writelog( main::LOG_ACTION, "Pretended to reload admin page to apply changes." );
    writelog( main::LOG_MESSAGE, "do_apply_changes: Returning success message." );
    return {
        'destination' => '/queue/freepbxreceiver ',
        'body' => "$msg_id" . "~success",
        'persistent' => 'true'
    };
} 

