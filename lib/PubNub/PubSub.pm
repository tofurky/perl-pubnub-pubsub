package PubNub::PubSub;

use strict;
use warnings;
use v5.10;

use Carp;
use Mojo::UserAgent;
use Mojo::Util qw/url_escape/;

use PubNub::PubSub::Message;

our $VERSION = '1.0.2';

sub new { ## no critic (RequireArgUnpacking)
    my $class = shift;
    my %args  = @_ % 2 ? %{$_[0]} : @_;

    $args{host} ||= 'pubsub.pubnub.com';
    $args{port} ||= 80;
    $args{timeout} ||= 60; # for ua timeout
    $args{publish_queue} ||= [];

    my $proto = ($args{port} == 443) ? 'https://' : 'http://';
    $args{web_host} ||= $proto . $args{host};

    return bless \%args, $class;
}

sub __ua {
    my $self = shift;

    return $self->{ua} if exists $self->{ua};

    my $ua = Mojo::UserAgent->new;
    $ua->max_redirects(3);
    $ua->inactivity_timeout($self->{timeout});
    $ua->proxy->detect; # env proxy
    $ua->cookie_jar->ignore(sub { 1 });
    $ua->max_connections(100);
    $self->{ua} = $ua;

    return $ua;
}

sub publish { ## no critic (RequireArgUnpacking)
    my $self = shift;

    my %params = @_ % 2 ? %{$_[0]} : @_;
    my $callback = $params{callback} || $self->{publish_callback};

    my $ua = $self->__ua;

    my @steps = map {
             my $ref = $_;
             my $url = $ref->{url};
             sub {
                 my $delay = shift;
                 my $end = $delay->begin;
                 $ua->get($url => sub {
                    $callback->($_[1]->res, $ref->{message}) if $callback;
                    $end->();
                  });
             }
    } $self->__construct_publish_urls(%params);

    return Mojo::IOLoop->delay(@steps)->wait;
}

sub __construct_publish_urls {
    my ($self, %params) = @_;

    my $pub_key = $params{pub_key} || $self->{pub_key};
    $pub_key or croak "pub_key is required.";
    my $sub_key = $params{sub_key} || $self->{sub_key};
    $sub_key or croak "sub_key is required.";
    my $channel = $params{channel} || $self->{channel};
    $channel or croak "channel is required.";
    $params{messages} or croak "messages is required.";

    return map {
        my $json = $_->json;
        my $uri = Mojo::URL->new( $self->{web_host} . qq~/publish/$pub_key/$sub_key/0/$channel/0/~ . url_escape($json) );
        $uri->query($_->query_params(\%params));
        { url => $uri->to_string, message => $_ };
    } map { PubNub::PubSub::Message->new($_) } @{$params{messages}};
}

sub subscribe { ## no critic (RequireArgUnpacking)
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;

    my $sub_key = $params{sub_key} || $self->{sub_key};
    $sub_key or croak "sub_key is required.";
    my $channel = $params{channel} || $self->{channel};
    $channel or croak "channel is required.";

    my $callback = $params{callback} or croak "callback is required.";
    my $timetoken = $params{timetoken} || '0';

    my $ua = $self->__ua;

    my $tx = $ua->get($self->{web_host} . "/v2/subscribe/$sub_key/$channel/0?tt=$timetoken");
    if ($tx->error) {
        # for example $tx->error->{message} =~ /Inactivity timeout/

        # This is not a traditional goto. Instead it exits this function 
        # and re-enters with @ as params.
        #
        # see goto docs, this is basically a method call which exits the current
        # function first.  So no extra call stack depth.
        sleep 1;
        @_ = ($self, %params, timetoken => $timetoken);
        goto &subscribe;
    }
    my $json = $tx->res->json;

    my $rtn = $callback ? $callback->($json) : 1;
    return unless $rtn;

    $timetoken = $json->{t}->{t};
    @_ = ($self, %params, timetoken => $timetoken);
    goto &subscribe;
}

sub subscribe_multi { ## no critic (RequireArgUnpacking)
    my $self = shift;
    my %params = @_ % 2 ? %{$_[0]} : @_;
    croak 'channels must be an arrayref'
         unless ref($params{channels}) =~ /ARRAY/;
    croak 'callback must be a hashref or coderef'
         unless ref($params{callback}) =~ /(HASH|CODE)/;

    my $callback;
    if (ref($params{callback}) =~ /HASH/){
       for (keys %{$params{callback}}) {
           croak "Non-coderef value found for callback key $_" 
                unless ref($params{callback}->{$_}) =~ /CODE/;
       }
=pod
Successful responses (200) return a three-element array:

Array Element 0 - Array - An array consisting of messages.

Array Element 1 - String - The next timetoken to connect with.

Array Element 2 - String - A CSV (not array) of the channels associated, in order, with the messages in array element 0. If the is an empty heartbeat response, or an empty initial timetoken 0 response, or you are only subscribed to a single channel or channel group, this element will not be returned.

Array Element 3 - String -When subscribed to one or more channel groups, array element 3 appears. It is a CSV (not array) of the "real channel" name associated with the channel group name.
=cut
=pod
An Object containing 2 elements:

First element is an object containing 2 values: t - String - the timetoken and r - Int - the region.

Second element is an array of messages, each message contains.

a - String - Shard
b - String - Subscription match or the channel group
c - String - Channel
d - Object - The payload
f - Int - Flags
i - String - Issuing Client Id
k - String - Subscribe Key
o - Object - Originating Timetoken, containing: t - String - the timetoken and r - Int - the region.
p - Object - Publish Timetoken Metadata containing: t - String - the timetoken and r - Int - the region.
u - Object - User Metadata
=cut
       $callback = sub {
           my $response = shift;
           my $timestamp = $response->{t}->{t};
           my %channels = ();
           foreach my $message (@{$response->{m}}) {
               my ($channel, $data) = ($message->{c}, $message->{d});
               next if(!defined($channel));
               $channels{$channel} = [] if(!exists($channels{$channel}));
               push(@{$channels{$channel}}, $data);
           }

           my $cb_dispatch = $params{callback};
           unless (scalar(keys %channels)) { # on connect messages
              goto $cb_dispatch->{on_connect}
                   if exists $cb_dispatch->{on_connect};
              return 1;
           }

           foreach my $channel (keys %channels) {
               if (exists $cb_dispatch->{$channel}) {
                   # these are verified coderefs, so replacing the current stack 
                   # frame with a call to the function.  They will *not* jump to 
                   # a label or other points.  Basically this just lets us pretend
                   # that this was called directly by subscribe above.
                   @_ = ($channels{$channel}, $timestamp, $channel);
                   goto $cb_dispatch->{$channel};
               } elsif (exists $cb_dispatch->{'_default'}) {
                   goto $cb_dispatch->{_default};
               } else {
                   warn 'Using callback dispatch table, cannot find channel callback'
                        . ' and _default callback not specified';
                   return;
               }
           }
       };
    }

    $callback = $params{callback} unless ref $callback;

    my $channel_string = join ',', @{$params{channels}};
    return $self->subscribe(channel => $channel_string, callback => $callback,
                           raw_msg => 1);
}

sub history { ## no critic (RequireArgUnpacking)
    my $self = shift;

    if (scalar(@_) == 1 and ref($_[0]) ne 'HASH' and $_[0] =~ /^\d+$/) {
        @_ = (count => $_[0]);
        warn "->history(\$num) is deprecated and will be removed in next few releases.\n";
    }

    my %params = @_ % 2 ? %{$_[0]} : @_;

    my $sub_key = delete $params{sub_key} || $self->{sub_key};
    $sub_key or croak "sub_key is required.";
    my $channel = delete $params{channel} || $self->{channel};
    $channel or croak "channel is required.";

    my $ua = $self->__ua;

    my $tx = $ua->get($self->{web_host} . "/v2/history/sub-key/$sub_key/channel/$channel" => form => \%params);
    return [$tx->error->{message}] unless $tx->success;
    return $tx->res->json;
}

1;
__END__

=encoding utf-8

=head1 NAME

PubNub::PubSub - Perl library for rapid publishing of messages on PubNub.com

=head1 SYNOPSIS

    use PubNub::PubSub;
    use 5.010;
    use Data::Dumper;

    my $pubnub = PubNub::PubSub->new(
        pub_key => 'demo', # only required for publish
        sub_key => 'demo',
        channel => 'sandbox',
    );

    # publish
    $pubnub->publish({
        messages => ['message1', 'message2'],
        callback => sub {
            my ($res) = @_;

            # $res is a L<Mojo::Message::Response>
            say $res->code; # 200
            say Dumper(\$res->json); # [1,"Sent","14108733777591385"]
        }
    });
    $pubnub->publish({
        channel  => 'sandbox2', # optional, if not applied, the one in ->new will be used.
        messages => ['message3', 'message4']
    });

    # subscribe
    $pubnub->subscribe({
        callback => sub {
            my (@messages) = @_;
            foreach my $msg (@messages) {
                print "# Got message: $msg\n";
            }
            return 1; # 1 to continue, 0 to stop
        }
    });


=head1 DESCRIPTION

PubNub::PubSub is Perl library for rapid publishing of messages on PubNub.com based on L<Mojo::UserAgent>

perl clone of L<https://gist.github.com/stephenlb/9496723#pubnub-http-pipelining>

For a rough test:

=over 4

=item * run perl examples/subscribe.pl in one terminal (or luanch may terminals with subscribe.pl)

=item * run perl examples/publish.pl in another terminal (you'll see all subscribe terminals will get messages.)

=back

=head1 METHOD

=head2 new

=over 4

=item * pub_key

optional, default pub_key for publish

=item * sub_key

optional, default sub_key for all methods

=item * channel

optional, default channel for all methods

=item * publish_callback

optional. default callback for publish

=item * debug

set ENV MOJO_USERAGENT_DEBUG to debug

=back

=head2 subscribe

subscribe channel to listen for the messages.

Arguments are:

=over

=item callback

Callback to run on the channel

=item channel

Channel to listen on, defaults to the base object's channel attribute.

=item subkey

Subscription key.  Defaults to base object's subkey attribute.

=item raw_msg

Pass the whole message in, as opposed to the json element of the payload.

This is useful when you need to process time tokens or channel names.

The format is a triple of (\@messages, $timetoken, $channel).

=item timetoken

Time token for initial request.  Defaults to 0.

=back

    $pubnub->subscribe({
        callback => sub {
            my (@messages) = @_;
            foreach my $msg (@messages) {
                print "# Got message: $msg\n";
            }
            return 1; # 1 to continue, 0 to stop
        }
    });

return 0 to stop

=head2 subscribe_multi

Subscribe to multiple channels.  Arguments are:

=over

=item channels

an arrayref of channel names

=item callback

A callback, either a coderef which handles all requests, or a hashref dispatch
table with one entry per channel.

If a dispatch table is used a _default entry catches all unrecognized channels.
If an unrecognized channel is found, a warning is generated and the loop exits.

The message results are passed into the functions in raw_msg form (i.e. a tuple
ref of (\@messages, $timetoken, $channel) for performance reasons.

=back

=head2 publish

publish messages to channel

    $pubnub->publish({
        messages => ['message1', 'message2'],
        callback => sub {
            my ($res) = @_;

            # $res is a L<Mojo::Message::Response>
            say $res->code; # 200
            say Dumper(\$res->json); # [1,"Sent","14108733777591385"]
        }
    });
    $pubnub->publish({
        channel  => 'sandbox2', # optional, if not applied, the one in ->new will be used.
        messages => ['message3', 'message4']
    });

Note if you need shared callback, please pass it when do ->new with B<publish_callback>.

new Parameters specifically for B<Publish V2 ONLY>

=over 4

=item * ortt - Origination TimeToken where "r" = DOMAIN and "t" = TIMETOKEN

=item * meta - any JSON payload - intended as a safe and unencrypted payload

=item * ear - Eat At Read (read once)

=item * seqn - Sequence Number - for Guaranteed Delivery/Ordering

=back

We'll first try to read from B<messages>, if not specified, fall back to the same level as messages. eg:

    $pubnub->publish({
        messages => [
            {
                message => 'test message.',
                ortt => {
                    "r" => 13,
                    "t" => "13978641831137500"
                },
                meta => {
                    "stuff" => []
                },
                ear  => 'True',
                seqn => 12345,
            },
            {
                ...
            }
        ]
    });

    ## if you have common part, you can specified as the same level as messages
    $pubnub->publish({
        messages => [
            {
                message => 'test message.',
                ortt => {
                    "r" => 13,
                    "t" => "13978641831137500"
                },
                seqn => 12345,
            },
            {
                ...
            }
        ],
        meta => {
            "stuff" => []
        },
        ear  => 'True',
    });

=head2 history

fetches historical messages of a channel

=over 4

=item * sub_key

optional, default will use the one passed to ->new

=item * channel

optional, default will use the one passed to ->new

=item * count

Specifies the number of historical messages to return. The Default is 100.

=item * reverse

Setting to true will traverse the time line in reverse starting with the newest message first. Default is false. If both start and end arguments are provided, reverse is ignored and messages are returned starting with the newest message.

=item * start

Time token delimiting the start of time slice (exclusive) to pull messages from.

=item * end

Time token delimiting the end of time slice (inclusive) to pull messages from.

=back

Sample code:

    my $history = $pubnub->history({
        count => 20,
        reverse => "false"
    });
    # $history is [["message1", "message2", ... ],"Start Time Token","End Time Token"]

for example, to fetch all the rows in history

    my $history = $pubnub->history({
        reverse => "true",
    });
    while (1) {
        print Dumper(\$history);
        last unless @{$history->[0]}; # no messages
        sleep 1;
        $history = $pubnub->history({
            reverse => "true",
            start => $history->[2]
        });
    }

=head1 JSON USAGE

This module effectively runs a Mojolicious application in the background.  For
those parts of JSON which do not have a hard Perl equivalent, such as booleans,
the Mojo::JSON module's semantics work.  This means that JSON bools are
handled as references to scalar values 0 and 1 (i.e. \0 for false and \1 for
true).

This has changed since 0.08, where True and False were used.

=head1 GITHUB

L<https://github.com/binary-com/perl-pubnub-pubsub>

=head1 AUTHOR

Binary.com E<lt>fayland@gmail.comE<gt>

=cut
