package PocketIO::Client::IO;

use strict;
use warnings;
use AnyEvent::PocketIO::Client;

our $VERSION = '0.01';

sub connect {
    my ( $clsas, $url ) = @_;
    my $client = AnyEvent::PocketIO::Client->new;
    my ( $server, $port ) = $url =~ m{https?://([.\w]+)(?::(\d+))?};

    $port ||= 80;

    my $socket;
    my $cv = AnyEvent->condvar;

    $client->handshake( $server, $port, sub {
        my ( $error, $self, $sesid, $hbtimeout, $contimeout, $transports ) = @_;

        if ( $error ) {
            Carp::carp( $error->{ message } );
            return $cv->send;
        }

        $self->open( sub {
            my ( $error, $self ) = @_;

            if ( $error ) {
                Carp::carp( $error->{ message } );
                return $cv->send;
            }

            $socket = $self->conn->socket;

            bless $socket, 'PocketIO::Socket::ForClient';

            $socket->{ _client } = $client;

            $cv->send;
        } );

    } );

    $cv->wait;

    return $socket;
}


package PocketIO::Socket::ForClient;

use base 'PocketIO::Socket';

sub on {
    my $self = shift;
    my ( $name, $cb ) = @_;

    if ( $name eq 'connect' ) {
        $cb->( $self ) if $cb;
    }
    else {
        $self->SUPER::on( @_ );
    }

}

1;

