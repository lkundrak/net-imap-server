use lib 't/lib';
use strict;
use warnings;

use Net::IMAP::Server::Test;
my $t = "Net::IMAP::Server::Test";

$t->start_server_ok;
$t->connect_ok;
$t->cmd_ok("LOGIN username password");
$t->cmd_like(
    "STATUS INBOX (MESSAGES UNSEEN)",
    '* STATUS "INBOX" (UNSEEN 0 MESSAGES 0)',
    "tag OK STATUS COMPLETED",
);
$t->disconnect;

done_testing;
