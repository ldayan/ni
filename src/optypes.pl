# Operator implementations

use File::Temp qw/tmpnam/;

# Meta
defop 'self', undef, '',
  'adds the source code of ni',
  sub { $_[0] + ni_memory(self) };

defop 'explain-stream', undef, '',
  'explains the current stream',
  sub { ni_memory($_[0]->explain) };

defop 'defined-methods', undef, '',
  'lists defined long and short methods on IO objects',
  sub { ni_memory(map "$_\n", grep /^_/, sort keys %{ni::io::}) };

DEBUG
defop 'debug-compile', undef, '',
  'shows the compiled code generated for the given io',
  sub {
    my $gen = $_[0]->source_gen(sink_as {
                with_input_type $_[0],
                  gen 'print:LV', {}, "print STDOUT \$_;"});
    ni_memory("\nCOMPILED\n" . $gen->compile,
              "\n",
              "\nDEBUG\n"    . $gen->debug_to_string);
  };
DEBUG_END

# Stream transforms
defop 'plus', undef, '',
  'adds two streams together (implied for files)',
  sub { $_[0] + $_[1] };

defop 'tee', undef, 's',
  'tees current output into the specified io',
  sub { $_[0] >>= tee_binding(ni $_[1]) };

# Functional transforms
defop 'map', 'm', 's',
  'transforms each record using the specified function',
  sub { $_[0] * $_[1] };

defop 'keep', 'k', 's',
  'keeps records for which the function returns true',
  sub { $_[0] % $_[1] };

defop 'deref', 'r', '',
  'interprets each record as a data source and emits it',
  sub { ni_cat($_[0] * \&ni) };

defop 'ref', 'R', 'V',
  'collects data into a file and emits the filename',
  sub { my $f = $_[1] // tmpnam;
        $_[0]->into(ni $_[1]);
        ni_memory($f) };

defop 'branch', 'b', 's',
  'splits input by its first field, forwarding to subprocesses',
  sub {
    my ($in, $subprocesses) = @_;
    my @subs = unpack_branch_map $subprocesses;
    my $fifo = ni::io::fifo->new->from(map ${$_}[1], @subs);

    unless (fork) {
      my $line;
      while (defined($line = <$in>)) {
        my ($k, $v) = split /\t/, $line, 2;
        for my $s (@subs) {
          if ($s->[0]->($k)) {
            $s->[1]->enqueue($line);
            last;
          }
        }
      }
      exit;
    }
    $fifo;
  };

# Sorting (shells out to command-line sort)
sub sort_options {
  my @fieldspec = split //, $_[0] // '';
  # TODO
}

defop 'order', 'o', 'AD',
  'order {n|N|g|G|l|L|u|U|m} [fields]',
  sub {
    my ($in, $flags, $fields) = @_;
    $in | 'sort';
  };
