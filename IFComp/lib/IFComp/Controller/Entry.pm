package IFComp::Controller::Entry;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

IFComp::Controller::Entry - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

use IFComp::Form::Entry;
use IFComp::Form::WithdrawEntry;

use MIME::Types;

use Readonly;
Readonly my $MAX_ENTRIES => 3;

has 'form' => (
    is => 'ro',
    isa => 'IFComp::Form::Entry',
    lazy_build => 1,
);

has 'withdrawal_form' => (
    is => 'ro',
    isa => 'IFComp::Form::WithdrawEntry',
    lazy_build => 1,
);

has 'entry' => (
    is => 'rw',
    isa => 'Maybe[IFComp::Schema::Result::Entry]',
);

sub root :Chained('/') :PathPart('entry') :CaptureArgs(0) {
    my ( $self, $c ) = @_;

    unless ( $c->user ) {
        $c->res->redirect( '/auth/login' );
        return;
    }

    my @entries = $c->user->get_object->current_comp_entries;

    my $current_comp = $c->model( 'IFCompDB::Comp' )->current_comp;

    $c->stash(
        entries => \@entries,
        current_comp => $current_comp,
    );

}

sub fetch_entry :Chained('root') :PathPart('') :CaptureArgs(1) {
    my ( $self, $c, $id ) = @_;

    my $entry = $c->model( 'IFCompDB::Entry' )->find( $id );
    if ( $entry && $entry->author->id eq $c->user->get_object->id ) {
        $c->stash->{ entry } = $entry;
        $self->entry( $entry );
    }
    else {
        $c->res->redirect( '/' );
    }
}

sub list :Chained('root') :PathPart('') :Args(0) {
    my ( $self, $c ) = @_;
}

sub preview :Chained('root') :PathPart('preview') :Args(0) {
    my ( $self, $c ) = @_;
}

sub create :Chained('root') :PathPart('create') :Args(0) {
    my ( $self, $c ) = @_;

    unless ( $c->stash->{ current_comp }->status eq 'accepting_intents' ) {
        $c->res->redirect( $c->uri_for_action( '/entry/list' ) );
    }

    unless (
        $c->model( 'IFCompDB::Entry' )->search( {
            author => $c->user->get_object->id,
            comp   => $c->stash->{ current_comp }->id,
        } )->count < $MAX_ENTRIES
    ) {
        $c->res->redirect( $c->uri_for_action( '/entry/list' ) );
    }

    my %new_result_args = (
        comp => $c->stash->{ current_comp },
        author => $c->user->get_object->id,
    );

    $c->stash( entry => $c->model( 'IFCompDB::Entry' )->new_result( \%new_result_args ) );
    if ( $self->_process_form( $c ) ) {
        $c->res->redirect( $c->uri_for_action( '/entry/list' ) );
    }
}

sub update :Chained('fetch_entry') :PathPart('update') :Args(0) {
    my ( $self, $c ) = @_;

    $self->_process_form( $c );

    $self->_process_withdrawal_form( $c );
}

sub cover :Chained('fetch_entry') :PathPart('cover') :Args(0) {
    my ( $self, $c ) = @_;

    my $file = $c->stash->{ entry }->cover_file;
    if ( -e $file ) {
        my $image_data = $file->slurp;
        if ( $file->basename =~ /png$/ ) {
            $c->res->content_type( 'image/png' );
        }
        else {
            $c->res->content_type( 'image/jpeg' );
        }
        $c->res->body( $image_data );
    }
    else {
        $c->res->code( 404 );
        $c->res->body( '' );
    }
}

sub current_comp_test :Chained('fetch_entry') :PathPart('test') :Args(0) {
    my ( $self, $c ) = @_;
}

sub transcript_list :Chained('fetch_entry') :PathPart('transcript') :Args(0) {
    my ( $self, $c ) = @_;

    my $session_rs = $c->model( 'IFCompDB::Transcript' )->search(
        {
            entry => $c->stash->{ entry }->id,
        },
        {
            select => [
                'session',
                { max => 'inputcount', -as => 'command_count' },
                { min => 'timestamp', -as => 'start_time' },
            ],
            as => [ qw( session_id command_count start_time ) ],
            group_by => 'session',
            order_by => 'start_time',
        },
    );

    $c->stash->{ session_rs } = $session_rs;

}

sub transcript :Chained('fetch_entry') :PathPart('transcript') :Args(1) {
    my ( $self, $c, $session_id ) = @_;

    my @inputs;
    my @output_sets;

    my $transcript_rs = $c->model( 'IFCompDB::Transcript' )->search(
        {
            session => $session_id,
        },
        {
            order_by => 'timestamp',
        },
    );

    my $current_input_count = 0;
    my $current_output_set_ref = [];
    while ( my $transcript = $transcript_rs->next ) {
        if ( $current_input_count != $transcript->inputcount ) {
            $current_input_count = $transcript->inputcount;
            push @inputs, $transcript->input;
            push @output_sets, $current_output_set_ref;
            $current_output_set_ref = [];
        }
        else {
            push @$current_output_set_ref, $transcript->output;
        }
    }
    push @output_sets, $current_output_set_ref;

    $c->stash(
        inputs      => \@inputs,
        output_sets => \@output_sets,
    );

}

sub _build_form {
    return IFComp::Form::Entry->new;
};

sub _build_withdrawal_form {
    return IFComp::Form::WithdrawEntry->new;
};

sub _process_form {
    my ( $self, $c ) = @_;

    $c->stash(
        form => $self->form,
        template => 'entry/update.tt',
    );

    my $params_ref = $c->req->parameters;
    foreach ( qw( main_upload walkthrough_upload cover_upload ) ) {
        my $param = "entry.$_";
        if ( $params_ref->{ $param } ) {
            $params_ref->{ $param } = $c->req->upload( $param );
        }
    }

    my $entry = $c->stash->{ entry };
    if ( $self->form->process( item => $entry, params => $params_ref, ) ) {
        # Handle files
        for my $upload_type ( qw( main walkthrough cover ) ) {
            my $deletion_param = "entry.${upload_type}_delete";
            if ( $params_ref->{ $deletion_param } ) {
                my $method = "${upload_type}_file";
                if ( my $file = $entry->$method ) {
                    $entry->$method->remove;
                    my $clearer = "clear_${upload_type}_file";
                    $entry->$clearer;
                }
            }

            my $upload_param = "entry.${upload_type}_upload";
            if ( my $upload = $params_ref->{ $upload_param } ) {
                my $file_method = "${upload_type}_file";
                if ( my $file = $entry->$file_method ) {
                    $file->remove;
                }
                my $directory_method = "${upload_type}_directory";
                my $result = $upload->copy_to(
                    $entry->$directory_method->file( $upload->filename )
                );
                unless ( $result ) {
                    die "Failed to write the $upload_type file.";
                }
                my $clearer = "clear_${upload_type}_file";
                $entry->$clearer;

                if ( $upload_type eq 'main' ) {
                    $entry->update_content_directory;
                }
            }

        }

        $c->flash->{ entry_updated } = 1;
        return 1;
    }
    else {
        return 0;
    }
}

sub _process_withdrawal_form {
    my ( $self, $c ) = @_;

    if ( $self->withdrawal_form->process( params => $c->req->parameters, ) ) {
        $c->stash->{ entry }->delete;
        $c->flash->{ entry_withdrawn } = $c->stash->{ entry }->title;
        $c->res->redirect( $c->uri_for_action( '/entry/list' ) );
    }

    $c->stash->{ withdrawal_form } = $self->withdrawal_form;

}

=encoding utf8

=head1 AUTHOR

Jason McIntosh

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
