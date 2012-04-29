use strict;
use warnings;

BEGIN {
    use Test::More;
    plan skip_all => 'Plack and Twiggy are required to run this test'
      unless eval { require Plack; require Twiggy; 1 };
}

use PocketIO::Test;

use AnyEvent;
use Plack::Builder;
use PocketIO;
use Data::Dumper;

use PocketIO::Client::IO;

my $app = builder {
    mount '/socket.io' => PocketIO->new(
        handler => sub {
            my $self = shift;
            $self->on('message' => sub {
                ok(1, "server recieved message. " . $_[1]);
            } );
            $self->on('hello' => sub {
                my ( $self, @data ) = @_;
                ok(1, "server hello");
                $self->send("hello, $data[0]");
            });
            $self->on('foo' => sub {
                my ( $self, @data ) = shift;
                ok(1, "server foo");
                $self->emit('bar');
            });
            ok(1, 'server handler runs');
        }
    );
};


my $server = '127.0.0.1';


test_pocketio(
    $app => \&_test
);

sub _test {
    my $port   = shift;
    my $socket = PocketIO::Client::IO->connect("http://$server:$port/");

    isa_ok( $socket, 'PocketIO::Socket' );

    my $cv = AnyEvent->condvar;
    my $w  = AnyEvent->timer( after => 5, cb => $cv );

    $socket->on( 'message', sub {
        ok(1, $_[1]);
    } );

    $socket->on( 'connect', sub {
        $socket->send('Parumon!');
        $socket->emit('hello', "perl");
    } );

    $cv->wait;
}


done_testing;

