#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use PubNub::PubSub;
use Time::HiRes qw/time/;

srand();
my $total_message = 20000; # 50000 + int(rand(50000));

my $got_message = 0;
my $start_time = time();
my $pubnub = PubNub::PubSub->new(
    pub_key => $ENV{PUBNUB_PUB_KEY} || 'pub-c-5b5d836f-143b-48d2-882f-659e87b6c321',
    sub_key => $ENV{PUBNUB_SUB_KEY} || 'sub-c-a66b65f2-2d96-11e4-875c-02ee2ddab7fe',
);

print "Total sending $total_message\n";
my @messages;
foreach (1 .. $total_message) {
    push @messages, "message" . $_;;
}
$pubnub->publish({
    messages => \@messages,
    channel  => $ENV{PUBNUB_CHANNEL} || 'sandbox',
    callback => sub {
        my ($res) = @_;

        # print "=" x 20 . "\n";
        # print "RES: $res" . "\n";
        # print "=" x 20 . "\n";

        $got_message++;
        if ($got_message == $total_message or $got_message % 1000 == 0) {
            my $duration = time() - $start_time;
            print "$got_message Spent $duration.\n";
        }
    }
});

my $duration = time() - $start_time;
print "Spent $duration.\n";

1;