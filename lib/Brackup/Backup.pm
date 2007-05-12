package Brackup::Backup;
use strict;
use warnings;
use Carp qw(croak);
use Brackup::ChunkIterator;

sub new {
    my ($class, %opts) = @_;
    my $self = bless {}, $class;

    $self->{root}    = delete $opts{root};     # Brackup::Root
    $self->{target}  = delete $opts{target};   # Brackup::Target
    $self->{dryrun}  = delete $opts{dryrun};   # bool
    $self->{verbose} = delete $opts{verbose};  # bool

    $self->{saved_files} = [];   # list of Brackup::File objects backed up

    croak("Unknown options: " . join(', ', keys %opts)) if %opts;

    return $self;
}

# returns true (a Brackup::BackupStats object) on success, or dies with error
sub backup {
    my ($self, $backup_file) = @_;

    my $root   = $self->{root};
    my $target = $self->{target};

    my $stats  = Brackup::BackupStats->new;

    my $gpg_rcpt = $self->{root}->gpg_rcpt;

    my $n_kb         = 0.0; # num
    my $n_files      = 0;   # int
    my $n_kb_done    = 0.0; # num
    my $n_files_done = 0;   # int
    my @files;         # Brackup::File objs

    $self->debug("Discovering files in ", $root->path, "...\n");
    $root->foreach_file(sub {
        my ($file) = @_;  # a Brackup::File
        push @files, $file;
        $n_files++;
        $n_kb += $file->size / 1024;
    });

    my $chunk_iterator = Brackup::ChunkIterator->new(@files);

    my $gpg_iter;
    if ($gpg_rcpt) {
        ($chunk_iterator, $gpg_iter) = $chunk_iterator->mux_into(2);
    }

    my $cur_file; # current (last seen) file
    my @stored_chunks;

    my $end_file = sub {
        return unless $cur_file;
        $self->add_file($cur_file, [ @stored_chunks ]);
        $n_files_done++;
        $n_kb_done += $cur_file->size / 1024;
        $cur_file = undef;
    };

    my $start_file = sub {
        $end_file->();
        $cur_file = shift;
        @stored_chunks = ();
        $self->debug(sprintf("* %-60s %d/%d (%0.02f%%; remain: %0.01f MB)",
                             $cur_file->path, $n_files_done, $n_files, ($n_kb_done/$n_kb)*100,
                             ($n_kb - $n_kb_done) / 1024));

        if ($gpg_iter) {
            # catch our gpg iterator up.  we want it to be ahead of us,
            # nothing iteresting is behind us.
            $gpg_iter->next while $gpg_iter->behind_by > 1;
        }
    };

    # records are either Brackup::File (for symlinks, directories, etc), or
    # PositionedChunks, in which case the file can asked of the chunk
    while (my $rec = $chunk_iterator->next) {
        if ($rec->isa("Brackup::File")) {
            $start_file->($rec);
            next;
        }
        my $pchunk = $rec;
        if ($pchunk->file != $cur_file) {
            $start_file->($pchunk->file);
        }

        my $schunk;
        if ($schunk = $target->stored_chunk_from_inventory($pchunk)) {
            $pchunk->forget_chunkref;
            push @stored_chunks, $schunk;
            next;
        }

        $self->debug("  * storing chunk: ", $pchunk->as_string, "\n");

        my $handle;
        unless ($self->{dryrun}) {
            #my $enc_filename = $gpg_rcpt ? $get_enc_filename->($pchunk) : undef;
            $schunk = Brackup::StoredChunk->new($pchunk); #, $enc_filename);
            $target->store_chunk($schunk)
                or die "Chunk storage failed.\n";
            $target->add_to_inventory($pchunk => $schunk);
            push @stored_chunks, $schunk;
        }

        #$stats->note_stored_chunk($schunk);

        # DEBUG: verify it got written correctly
        if ($ENV{BRACKUP_PARANOID} && $handle) {
            die "FIX UP TO NEW API";
            #my $saved_ref = $target->load_chunk($handle);
            #my $saved_len = length $$saved_ref;
            #unless ($saved_len == $chunk->backup_length) {
            #    warn "Saved length of $saved_len doesn't match our length of " . $chunk->backup_length . "\n";
            #    die;
            #}
        }

        $pchunk->forget_chunkref;
        $schunk->forget_chunkref if $schunk;
    }
    $end_file->();

    unless ($self->{dryrun}) {
        # write the metafile
        $self->debug("Writing metafile ($backup_file)");
        open (my $metafh, ">$backup_file") or die "Failed to open $backup_file for writing: $!\n";
        print $metafh $self->backup_header;
        $self->foreach_saved_file(sub {
            my ($file, $schunk_list) = @_;
            print $metafh $file->as_rfc822($schunk_list);  # arrayref of StoredChunks
        });
        close $metafh or die;

        my $contents;

        # store the metafile, encrypted, on the target
        if ($gpg_rcpt) {
            my $encfile = $backup_file . ".enc";
            system($self->{root}->gpg_path, $self->{root}->gpg_args,
                   "--trust-model=always",
                   "--recipient", $gpg_rcpt, "--encrypt", "--output=$encfile", "--yes", $backup_file)
                and die "Failed to run gpg while encryping metafile: $!\n";
            $contents = _contents_of($encfile);
            unlink $encfile;
        } else {
            $contents = _contents_of($backup_file);
        }

        # store it on the target
        my $name = $self->{root}->publicname . "-" . $self->backup_time;
        $target->store_backup_meta($name, $contents);
    }

    return $stats;
}

sub _contents_of {
    my $file = shift;
    open (my $fh, $file) or die "Failed to read contents of $file: $!\n";
    return do { local $/; <$fh>; };
}

sub backup_time {
    my $self = shift;
    return $self->{backup_time} ||= time();
}

sub backup_header {
    my $self = shift;
    my $ret = "";
    my $now = $self->backup_time;
    $ret .= "BackupTime: " . $now . " (" . localtime($now) . ")\n";
    $ret .= "BackupDriver: " . ref($self->{target}) . "\n";
    if (my $fields = $self->{target}->backup_header) {
        foreach my $k (keys %$fields) {
            die "Bogus header field from driver" unless $k =~ /^\w+$/;
            my $val = $fields->{$k};
            die "Bogus header value from driver" if $val =~ /[\r\n]/;
            $ret .= "Driver-$k: $val\n";
        }
    }
    $ret .= "RootName: " . $self->{root}->name . "\n";
    $ret .= "RootPath: " . $self->{root}->path . "\n";
    if (my $rcpt = $self->{root}->gpg_rcpt) {
        $ret .= "GPG-Recipient: $rcpt\n";
    }
    $ret .= "\n";
    return $ret;
}

sub add_file {
    my ($self, $file, $handlelist) = @_;
    push @{ $self->{saved_files} }, [ $file, $handlelist ];
}

sub foreach_saved_file {
    my ($self, $cb) = @_;
    foreach my $rec (@{ $self->{saved_files} }) {
        $cb->(@$rec);  # Brackup::File, arrayref of Brackup::StoredChunk
    }
}

sub debug {
    my ($self, @m) = @_;
    return unless $self->{verbose};
    my $line = join("", @m);
    chomp $line;
    print $line, "\n";
}

1;

