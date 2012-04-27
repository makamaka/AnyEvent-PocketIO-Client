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

use AnyEvent::PocketIO::Client;

use Storable;
use Safe;
use B::Deparse;

# for Test::SharedFork
eval q{ # avoiding warnings
    local $^W;
    $Storable::Deparse = 1;
    $Storable::Eval    = 1;
};



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
    use Test::More; # for Test::SharedFork

    my $port   = shift;
    my $client = AnyEvent::PocketIO::Client->new;    

    isa_ok( $client, 'AnyEvent::PocketIO::Client' );

    my $hb  = 0;
    my $cv2 = AnyEvent->condvar;

    $client->set_handler( sub {
        my ( $client ) = shift;
        $client->reg_event('message' => sub {
            ok(1, 'message ' . $_[1]);
            $cv2->end;
        });
        $client->reg_event('bar' => sub {
            ok(1, 'bar! <= foo');
            $cv2->end;
        });
    } );

    # main

    my $cv  = AnyEvent->condvar;

    $client->on( 'heartbeat' => sub {
        if ( ++$hb > 1 ) {
            diag("many hearbeat");
            $cv->send;
            $cv2->end;
            $cv2->end;
        }
    });

    $client->handshake( $server, $port, sub {
        my ( $self, $sesid, $hbtimeout, $contimeout, $transports ) = @_;
        ok( $sesid, sprintf("handshake:%s,%s,%s", $sesid, $hbtimeout, $contimeout) );

        $client->on( 'connect' => sub {
            ok(1, 'connect');
            $cv->send;
        });

        $client->connect();
    } );

    $cv->wait;

    $cv2->begin;
    $client->emit('hello', 'makamaka');
    $cv2->begin;
    $client->emit('foo');
    $cv2->wait;


    my $cv3 = AnyEvent->condvar;

    $client->on( 'disconnect' => sub {
        ok(1, 'disconnect');
    });

    $client->on( 'close' => sub {
        ok(1, 'socket closed');
        $cv3->send;
    });

    $client->disconnect;
    $cv3->wait;
   
    ok(1, 'test end');
}

done_testing;



