package Net::Server::IMAP::Command::Fetch;
use base qw/Net::Server::IMAP::Command/;

sub run {
    my $self = shift;

    return $self->bad_command("Login first") if $self->connection->is_unauth;
    return $self->bad_command("Select a mailbox first")
        unless $self->connection->is_selected;

    my $options = $self->options;
    my ( $messages, $spec ) = split( ' ', $options, 2 );

    my @messages = $self->connection->selected->get_messages($messages);
    for (@messages) {
        $self->untagged_response( $_->sequence
                . " FETCH "
                . $self->data_out( [ $_->fetch($spec) ] ) );
    }

    $self->ok_completed();
}

1;
