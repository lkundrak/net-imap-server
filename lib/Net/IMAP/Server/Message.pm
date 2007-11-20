package Net::IMAP::Server::Message;

use warnings;
use strict;
use bytes;

use Email::Address;
use Email::MIME;
use Email::MIME::ContentType;
use Regexp::Common qw/balanced/;
use DateTime;

# Canonical capitalization
my %FLAGS;
$FLAGS{lc $_} = $_ for qw(\Answered \Flagged \Deleted \Seen \Draft);

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(sequence mailbox uid _flags mime internaldate expunged));

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    $self->mime( Email::MIME->new(@_) ) if @_;
    $self->internaldate( DateTime->now->strftime("%e-%b-%Y %T %z") );
    $self->_flags( {} );
    return $self;
}

sub expunge {
    my $self = shift;
    $self->expunged(1);
}

sub copy_allowed {
    return 1;
}

sub mime_header {
    my $self = shift;
    return $self->mime->header_obj;
}

sub copy {
    my $self = shift;
    my $mailbox = shift;

    my $clone = bless {}, ref $self;
    $clone->mime( $self->mime ); # This leads to sharing the same MIME
                                 # object, but since they're
                                 # immutable, I don't think we care
    $clone->internaldate( $self->internaldate );  # Ditto for the date
    $clone->_flags( {} );
    $clone->set_flag( $_, 1 ) for ('\Recent', $self->flags);

    $mailbox->add_message($clone);

    return $clone;
}

sub set_flag {
    my $self = shift;
    my $flag = shift;
    $flag = $FLAGS{lc $flag} || $flag;
    my $old  = exists $self->_flags->{$flag};
    $self->_flags->{$flag} = 1;

    my $changed = not $old;
    if ($changed and not @_) {
        for my $c (Net::IMAP::Server->concurrent_mailbox_connections($self->mailbox)) {
            $c->untagged_fetch->{$c->sequence($self)}{FLAGS}++ unless $c->ignore_flags;
        }
    }
    
    return $changed;
}

sub clear_flag {
    my $self = shift;
    my $flag = shift;
    $flag = $FLAGS{lc $flag} || $flag;
    my $old  = exists $self->_flags->{$flag};
    delete $self->_flags->{$flag};

    my $changed = $old;
    if ($changed and not @_) {
        for my $c (Net::IMAP::Server->concurrent_mailbox_connections($self->mailbox)) {
            $c->untagged_fetch->{$c->sequence($self)}{FLAGS}++ unless $c->ignore_flags;
        }
    }

    return $changed;
}

sub has_flag {
    my $self = shift;
    my $flag = shift;
    $flag = $FLAGS{lc $flag} || $flag;
    return exists $self->_flags->{$flag};
}

sub flags {
    my $self = shift;
    return sort keys %{ $self->_flags };
}

sub fetch {
    my $self = shift;
    my $spec = shift;

    $spec = [qw/FLAGS INTERNALDATE RFC822.SIZE ENVELOPE/] if uc $spec eq "ALL";
    $spec = [qw/FLAGS INTERNALDATE RFC822.SIZE/]          if uc $spec eq "FAST";
    $spec = [qw/FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY/]
        if uc $spec eq "FULL";

    my @parts = ref $spec ? @{$spec} : $spec;

    # Look if this will change the \Seen flag
    if ( grep { $_ =~ /^BODY\[/i } @parts and not $self->has_flag('\Seen') ) {

        # If so, update, and possibly also inform the user.
        $self->set_flag('\Seen');
        push @parts, "FLAGS" if not grep { uc $_ eq "FLAGS" } @parts;
    }

    my @out;
    for my $part (@parts) {
        push @out, \(uc $part);

        # Now that we've split out the right tag, do some aliasing
        if ( uc $part eq "RFC822" ) {
            $part = "BODY[]";
        } elsif ( uc $part eq "RFC822.HEADER" ) {
            $part = "BODY.PEEK[HEADER]";
        } elsif ( uc $part eq "RFC822.TEXT" ) {
            $part = "BODY[TEXT]";
        }

        if ( uc $part eq "UID" ) {
            push @out, $self->uid;
        } elsif ( uc $part eq "INTERNALDATE" ) {
            push @out, $self->internaldate;
        } elsif ( $part
            =~ /^BODY(?:\.PEEK)?\[(.*?)(?:\s+\((.*?)\))?\](?:<(\d+)(?:\.(\d+))>)?$/i
            )
        {
            push @out,
                $self->mime_select( [ split /\./, $1 ],
                $3, $4, [ split ' ', ( $2 || "" ) ] );
            ${ $out[-2] } =~ s/^BODY\.PEEK/BODY/i;
        } elsif ( uc $part eq "FLAGS" ) {
            push @out, [ map { \$_ } $self->flags ];
        } elsif ( uc $part eq "RFC822.SIZE" ) {
            push @out, length $self->mime_select( [], undef, undef );
        } elsif ( uc $part eq "BODY" ) {
            push @out, $self->mime_bodystructure( $self->mime, 0 );
        } elsif ( uc $part eq "BODYSTRUCTURE" ) {
            push @out, $self->mime_bodystructure( $self->mime, 1 );
        } elsif ( uc $part eq "ENVELOPE" ) {
            push @out, $self->mime_envelope;
        } else {
            pop @out;
        }
    }
    return @out;
}

sub mime_select {
    my $self = shift;
    my ( $sections, $start, $end, $extras ) = @_;

    my $mime;

    my @sections = @{$sections};
    my $result;
    $result = $self->mime->as_string unless @sections;
    for (@sections) {
        if ( uc $_ eq "HEADER" or uc $_ eq "MIME" ) {
            $result = ($mime ? $mime->header_obj : $self->mime_header)->as_string . "\r\n";
        } elsif ( uc $_ eq "FIELDS" ) {
            my %case;
            my $mime_header = $mime ? $mime->header_obj : $self->mime_header;
            $case{ uc $_ } = $_ for $mime_header->header_names;
            my $copy = Email::Simple::Header->new("");
            for my $h ( @{$extras} ) {
                $copy->header_set( $case{$h} || $h => $mime_header->header($h) );
            }
            $result = $copy->as_string ? $copy->as_string . "\r\n" : "";
        } elsif ( uc $_ eq "TEXT" ) {
            $mime ||= $self->mime;
            $result = $mime->body;
        } elsif ( $_ =~ /^\d+$/i ) {
            $mime ||= $self->mime;
            my @parts = $mime->parts;
            $mime   = $parts[ $_ - 1 ];
            $result = $mime->body;
        }
    }

    return $result unless defined $start;
    return substr( $result, $start ) unless defined $end;
    return substr( $result, $start, $end );
}

sub mime_bodystructure {
    my $self = shift;
    my ( $mime, $long ) = @_;

    # Grab the content type
    my $data = parse_content_type( $mime->content_type );

    # And the content disposition
    my $dis_header = $mime->header("Content-Disposition");
    my ( $attrs, $disposition );
    if ($dis_header) {

        # Ugly hack.  Culled from Email::MIME::Modifier
        ($disposition) = ( $dis_header =~ /^([^;]+)/ );
        $dis_header =~ s/^$disposition(?:;\s*)?//;
        $attrs = Email::MIME::ContentType::_parse_attributes($dis_header);
    }

    if ( $data->{discrete} eq "multipart" ) {

        # The first element is a binch of lists, which looks like
        # (...)(...) -- note the lack of space!  RFC 3501, how do we
        # hate thee.  Make the mime structures, hack them into the
        # IMAP format, concat them, and insert their reference so they
        # get spat out as-is.
        my @parts        = $mime->parts;
        @parts = () if @parts == 1 and $parts[0] == $mime;
        my $parts = join '', map {
            Net::IMAP::Server::Command->data_out( $self->mime_bodystructure( $_, $long ) )
        } @parts;

        return [
            $parts ? \$parts : undef,
            $data->{composite},
            (   $long
                ? ( (   %{ $data->{attributes} }
                        ? [ %{ $data->{attributes} } ]
                        : undef
                    ),
                    (   $disposition
                        ? [ $disposition,
                            ( $attrs && %{$attrs} ? [ %{$attrs} ] : undef ),
                            ]
                        : undef
                    ),
                    scalar $mime->header("Content-Language"),
                    scalar $mime->header("Content-Location"),
                    )
                : ()
            ),
        ];
    } else {
        my $lines;
        my $body = $mime->body_raw;
        if ( lc $data->{discrete} eq "text" ) {
            $lines = 0;
            $lines++ while $body =~ /\n/g;
        }
        return [
            $data->{discrete},
            $data->{composite},
            (   %{ $data->{attributes} }
                ? [ %{ $data->{attributes} } ]
                : undef
            ),
            scalar $mime->header("Content-ID"),
            scalar $mime->header("Content-Description"),
            ( scalar $mime->header("Content-Transfer-Encoding") or "7BIT" ),
            length $body,
            (   defined $lines
                ? ( $lines, )
                : ()
            ),
            (   $long
                ? ( scalar $mime->header("Content-MD5"),
                    (   $disposition
                        ? [ $disposition,
                            ( $attrs && %{$attrs} ? [ %{$attrs} ] : undef ),
                            ]
                        : undef
                    ),
                    scalar $mime->header("Content-Language"),
                    scalar $mime->header("Content-Location"),
                    )
                : ()
            ),
        ];
    }
}

sub address_envelope {
    my $self   = shift;
    my $header = shift;
    my $mime   = $self->mime_header;

    return undef unless $mime->header($header);
    return [ map { [ {type => "string", value => $_->name},
                     undef,
                     {type => "string", value => $_->user},
                     {type => "string", value => $_->host}
                   ] }
            Email::Address->parse( $mime->header($header) ) ];
}

sub mime_envelope {
    my $self = shift;
    my $mime = $self->mime_header;

    return [
        scalar $mime->header("Date"),
        scalar $mime->header("Subject"),

        $self->address_envelope("From"),
        $self->address_envelope(
            $mime->header("Sender") ? "Sender" : "From"
        ),
        $self->address_envelope(
            $mime->header("Reply-To") ? "Reply-To" : "From"
        ),
        $self->address_envelope("To"),
        $self->address_envelope("Cc"),
        $self->address_envelope("Bcc"),

        scalar $mime->header("In-Reply-To"),
        scalar $mime->header("Message-ID"),
    ];
}

sub store {
    my $self = shift;
    my ( $what, $flags ) = @_;
    my @flags = @{$flags};
    if ( $what =~ /^-/ ) {
        $self->clear_flag($_) for grep { $self->has_flag($_) } @flags;
    } elsif ( $what =~ /^\+/ ) {
        $self->set_flag($_) for grep { not $self->has_flag($_) } @flags;
    } else {
        $self->set_flag($_) for grep { not $self->has_flag($_) } @flags;
        $self->clear_flag($_) for grep {
            $a = $_;
            not grep { lc $a eq lc $_ } @flags
        } $self->flags;
    }
}

sub prep_for_destroy {
    my $self = shift;
    $self->mailbox(undef);
}

1;
