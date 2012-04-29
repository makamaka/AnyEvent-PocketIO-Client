package AnyEvent::PocketIO::Client;

use strict;
use warnings;
use Carp ();
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use PocketIO::Handle;
use PocketIO::Connection;
use Protocol::WebSocket::Frame;
use Protocol::WebSocket::Handshake::Client;

my %RESERVED_EVENT = map { $_ => 1 }
                        qw/message connect disconnect open close error retry reconnect/;

our $VERSION = '0.01';


sub new {
    my $this  = shift;
    my $class = ref $this || $this;
    bless {
        handshake_timeout => 10,
        open_timeout      => 10,
        @_,
    }, $class;
}

sub handle { $_[0]->{ handle }; }

sub conn { $_[0]->{ conn }; }

sub socket { $_[0]->conn->socket; }

sub _start_timer {
    my ( $self, $timer_name, $cb ) = @_;
    my $after = $self->{ "${timer_name}_timeout" } || 0;
    $self->{ "${timer_name}_timer" } = AnyEvent->timer( after => $after, cb => $cb );
}

sub _stop_timer {
    my ( $self, $timer_name ) = @_;
    delete $self->{ "${timer_name}_timer" };
}

sub handshake {
    my ( $self, $host, $port, $cb ) = @_;

    $cb ||= sub {};

    tcp_connect( $host, $port,
        sub {
            my ($fh) = @_ or return $cb->( { code => 500, message => $! }, $self );

            @{$self}{qw/host port/} = ( $host, $port );

            my $socket = AnyEvent::Handle->new(
                fh => $fh,
                on_error => sub {
                    $self->disconnect(join(',', "error!:", $_[1], $_[2] ));
                },
            );

            $socket->push_write("GET /socket.io/1/ HTTP/1.1\nHost: $host:$port\n\n");

            my $read = 0; # handshake is finished?

            $self->_start_timer( 'handshake', sub {
                $socket->fh->close;
                $read++;
                $self->_stop_timer( 'handshake' );
                $cb->( { code => 500, message => 'Handshake timeout.' }, $self );
            } );

            $socket->on_read( sub {
                return unless length $_[0]->rbuf;
                return if $read;

                my ( $status_line ) = $_[0]->rbuf =~ /^(.+)\015\012/;
                my ( $code ) = $status_line =~ m{^HTTP/[.01]+ (\d+) };
                my $error;

                if ( $code && $code != 200 ) {
                    $_[0]->rbuf =~ /\015\012\015\012(.*)/sm;
                    $error = { code => $code, message => $1 };
                    $read++;
                    $cb->( $error, $self );
                    return;
                }

                my ( $line ) = $_[0]->rbuf =~ /\015\012\015\012([^:]+:[^:]+:[^:]+:[^:]+)/sm;

                unless ( defined $line ) {
                    return;
                }

                $self->_stop_timer( 'handshake' );

                my ( $sid, $hb_timeout, $con_timeout, $transports ) = split/:/, $line;
                $transports = [split/,/, $transports];
                $self->{ acceptable_transports } = $transports;
                $self->{ session_id } = $sid;
                $socket->destroy;
                $read++;
                $cb->( $error, $self, $sid, $hb_timeout, $con_timeout, $transports );
            } );
    } );

}

sub _build_frame {
    my $self = shift;
    return Protocol::WebSocket::Frame->new( @_ )->to_bytes;
}

sub is_opened {
    $_[0]->{ is_opened };
}

sub opened {
    $_[0]->{ is_opened } = 1;
}

sub reg_event {
    my ( $self, $name, $cb ) = @_;
    return Carp::carp('reg_event() must take a code reference.') if $cb && ref($cb) ne 'CODE';
    return Carp::carp("reg_event() must be called after connected.") unless $self->is_opened;
    return Carp::carp("$name is reserved event.") if exists $RESERVED_EVENT{ $name }; 
    $self->conn->socket->on( $name => $cb );
}

sub on {
    my ( $self, $event ) = @_;
    my $name = "on_$event";

    if ( @_ > 2 ) {
        $self->{ $name } = $_[2];
        return $self;
    }

    return $self->{ $name } ||= sub {};
}

sub disconnect {
    my ( $self ) = @_;

    return unless $self->is_opened;

    $self->{ is_opened } = 0;
    $self->on('disconnect')->();
    $self->conn->close;
    $self->conn->disconnected;
    delete $self->{ conn };
}

sub emit {
    my $self = shift;
    unless ( $self->is_opened ) {
        Carp::carp('Not yet connected.');
        return;
    }
    $self->conn->socket->emit( @_ );
}

sub send {
    my $self = shift;
    unless ( $self->is_opened ) {
        Carp::carp('Not yet connected.');
        return;
    }
    $self->conn->socket->send( @_ );
}

sub connect {
    my ( $self, $endpoint ) = @_;
    $self->conn->_stop_timer('close');
    my $message = PocketIO::Message->new(type => 'connect');
    $self->conn->write($message);
    $self->conn->_start_timer('close');
    #$self->conn->emit('connect');    
    $self->on('connect')->( $endpoint );
}

sub transport_id {
    $_[0]->{ transport_id } = $_[0] if @_ > 1;
    $_[0]->{ transport_id };
}

sub open {
    my ( $self, $trans, $cb ) = @_;
    my $host = $self->{ host };
    my $port = $self->{ port };
    my $sid  = $self->{ session_id };

    return Carp::carp("Tried open() but no session id.") && 0 unless $sid;

    if ( $trans && ref $trans eq 'CODE' ) {
        $cb = $trans; $trans = undef;
    }

    $trans = 'websocket'; # TODO ||= $self->{ acceptable_transports }->[0];
    # TODO: setup transport class
    $self->transport_id( $trans );

    tcp_connect( $host, $port,
         sub {
            my ($fh) = @_ or die $!;
            my $hs = Protocol::WebSocket::Handshake::Client->new(url =>
                  "ws://$host:$port/socket.io/1/$trans/$sid");
            my $frame  = Protocol::WebSocket::Frame->new( version => $hs->version );
            $self->{ handle } = PocketIO::Handle->new(
                fh => $fh, heartbeat_timeout => $self->{ heartbeat_timeout }
            );

            my $conn = $self->{ conn } = PocketIO::Connection->new();

            $self->handle->write( $hs->to_string => sub {
                my ( $handle ) = shift;

                my $close_cb = sub { $handle->close; };

                $handle->on_eof( $close_cb );
                $handle->on_error( $close_cb );

                $handle->on_heartbeat( sub {
                    $conn->send_heartbeat;
                    $self->on('heartbeat')->();
                } );

                $handle->on_read( sub {
                    unless ( $self->is_opened ) {
                        $self->opened;
                        $cb->( $self ) if $cb; # may set event handler
                        # default setting
                        for my $name ( qw/connect message disconnect error/ ) {
                            $conn->socket->on( $name => sub {} ) unless $conn->socket->on( $name );
                        }
                        #$conn->socket->on('connect')->( $conn->socket );
                    }

                    unless ($hs->is_done) {
                        $hs->parse( $_[1] ); 
                        return;
                    }
                    $frame->append( $_[1] );

                    while ( my $message = $frame->next_bytes ) {
                        $conn->parse_message( $message );
                    }
                } );

                $conn->on(
                    close => sub {
                        $handle->close;
                        $self->on('close')->();
                    }
                );

                $conn->on(
                    write => sub {
                        my $bytes = $self->_build_frame(
                            buffer => $_[1], version => $hs->version,
                        );
                        $handle->write( $bytes );
                    },
                );

                $conn->socket->on('message' => sub {
                    $self->on('message')->( $conn->socket, $_[1] );
                });

            });
        }
    );

}



1;
__END__

=pod

=head1 NAME

AnyEvent::PocketIO::Client - pocketio client

=head1 SYNOPSIS

    use AnyEvent;
    use AnyEvent::PocketIO::Client;
    
    my $client = AnyEvent::PocketIO::Client->new;    

    $client->on('message' => sub {
        print STDERR "get message : $_[1]\n";
    });

    # first handhake, then open.
    
    my $cv = AnyEvent->condvar;

    $client->handshake( $server, $port, sub {
        my ( $error, $self, $sesid, $hb_timeout, $con_timeout, $trans ) = @_;

        $client->open( 'websocket' => sub {

            $self->reg_event('foo' => sub {
                # ...
            });

            $cv->send;
        } );

    } );
    
    $cv->wait;
    
    # ... loop, timer, etc.
    
    $client->disconnect;

=head1 DESCRIPTION

Async client using AnyEvent.

This is B<beta> version!

API will be changed.

Currently acceptable transport id is websocket only.

=head1 METHODS

=head2 new

    $client = AnyEvent::PocketIO::Client->new( %opts )

C<new> takes options

=over

=item handshake_timeout

=back

=head2 handshake

    $client->handshake( $host, $port, $cb );

The handshake routine. it executes a call back C<$cb> that takes
error, client itself, session id, heartbeat timeout, connection timeout
and list reference of transports.

    sub {
        my ( $error, $client, $sesid, $hb_timeout, $conn_timeout, $trans ) = @_;
        if ( $error ) {
            say "code:", $error->{ code };
            say "message:", $error->{ message };
        }
        # ...        
    }

=head2 open

    $client->open( $transport_id, $cb );

=head2 is_opened

    $boolean = $client->is_opend

=head2 connect

    $client->connect( $endpoint )

=head2 disconnect

    $client->disconnect( $endpoint )

=head2 reg_event

    $client->reg_event( 'name' => $subref )

=head2 emit

    $client->emit( 'event_name', @args )

=head2 send

    $client->send( 'message' )

=head2 conn

    $conn = $client->conn; # PocketIO::Connection

=head2 on

    $client->on( 'messsage_type' => $cb );

Acceptable types are 'connect', 'disconnect', 'heartbeat' and 'message'.

=head1 SEE ALSO

L<AnyEvent>, L<PocketIO>

=head1 AUTHOR

Makamaka Hannyaharamitu, E<lt>makamaka[at]cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2012 by Makamaka Hannyaharamitu

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut




