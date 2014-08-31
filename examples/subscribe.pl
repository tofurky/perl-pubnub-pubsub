#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw/$Bin/;
use lib "$Bin/../lib";
use PubNub::PubSub;
use Data::Dumper;

my $pubnub = PubNub::PubSub->new(
    pub_key => $ENV{PUBNUB_PUB_KEY} || 'pub-c-5b5d836f-143b-48d2-882f-659e87b6c321',
    sub_key => $ENV{PUBNUB_SUB_KEY} || 'sub-c-a66b65f2-2d96-11e4-875c-02ee2ddab7fe',
    debug => 1, # test
);

$pubnub->subscribe({
    channel  => $ENV{PUBNUB_CHANNEL} || 'sandbox',
    callback => sub {
        my (@messages) = @_;
        foreach my $msg (@messages) {
        #    print "# Got message: $msg\n";
        }
        return 1; # 1 to continue, 0 to stop
    }
});

1;