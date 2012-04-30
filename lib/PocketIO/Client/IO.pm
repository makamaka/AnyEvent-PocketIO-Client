package PocketIO::Client::IO;

use strict;
use warnings;
use AnyEvent::PocketIO::Client;
use Scalar::Util ();

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
            $cv->send;
            return;
        }

        $self->on('open' => sub {
            $cv->send;
        });

        $self->open();

        return;
    } );

    $cv->wait;

    return unless $client->conn;

    $socket = $client->conn->socket;

    bless $socket, 'PocketIO::Socket::ForClient';

    $socket->{ _client } = $client;
    Scalar::Util::weaken( $socket->{ _client } );

    return $socket;
}


package PocketIO::Socket::ForClient;

use base 'PocketIO::Socket';

sub on {
    my $self = shift;
    my ( $name, $cb ) = @_;

    if ( $name eq 'connect' and $cb ) {
        my $w; $w = AnyEvent->timer( after => 0, interval => 1, cb => sub {
            if ( $self->{ _client }->is_opened ) {
                undef $w;
                $cb->( $self );
            }
        } );
    }
    else {
        $self->SUPER::on( @_ );
    }

}

1;

