package AnyEvent::PocketIO::Client;

use strict;
use warnings;
use Carp ();
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use PocketIO::Handle;
use Protocol::WebSocket::Frame;
use Protocol::WebSocket::Handshake::Client;


our $VERSION = '0.01';


sub new {
    my $this  = shift;
    my $class = ref $this || $this;
    bless {}, $class;
}

sub handle { $_[0]->{ handle }; }

sub conn { $_[0]->{ conn }; }

sub socket { $_[0]->conn->socket; }

sub handshake {
    my ( $self, $host, $port, $cb ) = @_;

    tcp_connect( $host, $port,
        sub {
            my ($fh) = @_ or die $!;

            @{$self}{qw/host port/} = ( $host, $port );

            my $socket = AnyEvent::Handle->new(
                fh => $fh,
                on_error => sub {
                    $self->disconnect(join(',', "error!:", $_[1], $_[2] ));
                },
            );

            $socket->push_write("GET /socket.io/1/ HTTP/1.1\nHost: $host:$port\n\n");

            $socket->on_read( sub {
                my ( $line ) = $_[0]->rbuf =~ /\015\012\015\012(.+)/sm;
                return unless defined $line;
                my ( $sid, $hb_timeout, $con_timeout, $transports ) = split/:/, $line;
                $transports = [split/,/, $transports];
                $self->{ acceptable_transports } = $transports;
                $self->{ session_id } = $sid;
                $socket->destroy;
                $cb->( $self, $sid, $hb_timeout, $con_timeout, $transports ) if $cb;
            } );
    } );
}

sub _build_frame {
    my $self = shift;
    return Protocol::WebSocket::Frame->new( @_ )->to_bytes;
}

sub is_connected {
    $_[0]->{ is_connected };
}

sub connected {
    $_[0]->{ is_connected } = 1;
}

sub reg_event {
    my ( $self, $name, $cb ) = @_;
    return Carp::carp('reg_event() must take a code reference.') if $cb && ref($cb) ne 'CODE';
    return Carp::carp("reg_event() must be called after connected.") unless $self->is_connected;
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

    return unless $self->is_connected;

    $self->{ is_connected } = 0;
    $self->on('disconnect')->();
    $self->conn->close;
    $self->conn->disconnected;
    delete $self->{ conn };
}

sub set_handler {
    die "set_handler must take subroutine reference."
        unless $_[1] and ref($_[1]) eq 'CODE';
    $_[0]->{ handler } = $_[1];
}

sub emit {
    my $self = shift;
    unless ( $self->is_connected ) {
        Carp::carp('Not yet connected.');
        return;
    }
    $self->conn->socket->emit( @_ );
}

sub send {
    my $self = shift;
    unless ( $self->is_connected ) {
        Carp::carp('Not yet connected.');
        return;
    }
    $self->conn->socket->send( @_ );
}


sub connect {
    my ( $self, $trans ) = @_;
    my $host = $self->{ host };
    my $port = $self->{ port };
    my $sid  = $self->{ session_id };

    return Carp::carp("Tried connect() but no session id.") && 0 unless $sid;

    $trans = 'websocket'; # TODO ||= $self->{ acceptable_transports }->[0];
    # TODO: setup transport class

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

                my $close_cb = sub { $handle->close; $self->event('close'); };

                $handle->on_eof( $close_cb );
                $handle->on_error( $close_cb );

                $handle->on_heartbeat( sub {
                    $conn->send_heartbeat;
                    $self->on('heartbeat')->();
                } );

                $handle->on_read( sub {
                    unless ($hs->is_done) {
                        $hs->parse( $_[1] ); 
                        return;
                    }
                    $frame->append( $_[1] );

                    while ( my $message = $frame->next_bytes ) {
                        unless ( $self->is_connected ) {
                            if ( $message =~ /^1::/ ) {
                                #$self->conn->connected;
                                $self->connected;
                                my $cb = $self->{ handler } || sub {};
                                $cb->( $self ); # call handler
                                for my $name ( qw/connect message disconnect error/ ) {
                                    $conn->socket->on( $name => sub {} )
                                            unless $conn->socket->on( $name );
                                }
                                #$conn->socket->on('connect')->( $conn->socket );
                                $self->on('connect')->( $self );
                            }
                        }

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
    my $cv     = AnyEvent->condvar;
    
    $client->set_handler( sub {
        my ( $self ) = shift;
        $self->reg_event('message' => sub {
            print STDERR "get message : $_[1]\n";
        });
        $self->reg_event('foo' => sub {
            # ...
            $cv->end;            
        });
    } );
    
    my $cv2  = AnyEvent->condvar;
    
    $client->handshake( $server, $port, sub {
        my ( $self, $sesid, $hb_timeout, $con_timeout, $transports ) = @_;

        $self->on( 'connect' => sub {
            $cv2->send;
        });

        $client->connect();
    } );
    
    $cv2->wait;
    
    $cv->begin;
    $client->emit('bar');
    $cv->wait;
    
    $client->disconnect;

=head1 DESCRIPTION

This is B<beta> version!

=head1 SEE ALSO

L<AnyEvent>, L<PocketIO>

=head1 AUTHOR

Makamaka Hannyaharamitu, E<lt>makamaka[at]cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2012 by Makamaka Hannyaharamitu

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut




