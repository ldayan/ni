# High-level pipe operations, each of which corresponds to a command-line
# option. They can also be used from compiled code.

our %op_shorthand_lookups;      # keyed by short
our %op_shorthands;             # keyed by long
our %op_formats;                # ditto
our %op_usage;                  # ditto
our %op_fns;                    # ditto

sub long_op_method  { "--$_[0]" =~ s/-/_/gr }
sub short_op_method { "_$_[0]" }

sub shell_quote { join ' ', map /[^-\/\w]/ ? "'" . s/(['\\])/'\\$1'/gr . "'"
                              : length $_  ? $_
                              :              "''", @_ }

sub self_pipe { ni_process(shell_quote('perl', '-', @_),
                           ni_memory(self)->reader_fh,
                           undef) }

sub defop {
  my ($long, $short, $format, $usage, $fn) = @_;
  if (defined $short) {
    $op_shorthands{$long}         = $short;
    $op_shorthand_lookups{$short} = "--$long";
  }
  $op_formats{$long} = $format;
  $op_usage{$long}   = $usage;
  $op_fns{$long}     = $fn;

  my $long_method_name = long_op_method $long;
  my $short_method_name =
    defined $short ? short_op_method $short : undef;

  die "operator $long already exists (possibly as a method rather than an op)"
    if exists $ni::io::{$long_method_name}
    or defined $short_method_name && exists $ni::io::{$short_method_name};

  # Enable programmatic access
  *{"ni::io::$short_method_name"} = $fn if defined $short_method_name;
  *{"ni::io::$long_method_name"}  = $fn;
}

our %format_matchers = (
  a => sub {              $_[0] =~ /^[a-zA-Z]+$/ },
  d => sub {              $_[0] =~ /^[-+\.0-9]+$/ },
  s => sub { ref $_[0] || $_[0] =~ /^.*$/ },
  v => sub {              $_[0] =~ /^[^-].*$/ },
);

sub apply_format {
  my ($format, @args) = @_;
  my @format = split //, $format;
  my @parsed;

  for (@format) {
    die "too few arguments for format $format" if !@args && !/[A-Z]/;
    my $a = shift @args;
    if ($format_matchers{lc $_}->($a)) {
      push @parsed, $a;
    } else {
      die "failed to match format $format" unless /[A-Z]/;
      push @parsed, undef;
      unshift @args, $a if defined $a;
    }
  }

  \@parsed, @args;
}

sub file_opt { ['plus', ni $_[0]] }
sub parse_commands {
  my @parsed;
  for (my $o; defined($o = shift @_);) {
    return @parsed, map file_opt($_), @_ if $o eq '--';

    # Special cases
    if (ref($o) eq '[') {
      # Lambda-invocation of ni on the specified options.
      push @parsed, ['plus', self_pipe @$o];
    } elsif (ref $o) {
      die "ni: unknown bracket group type " . ref($o) . " to use as a command";
    } elsif ($o =~ /^--/) {
      my $c = $o =~ s/^--//r;
      die "unknown long command: $o" unless exists $op_fns{$c};
      my ($args, @rest) = apply_format $op_formats{$c}, @_;
      push @parsed, [$c, @$args];
      @_ = @rest;
    } elsif ($o =~ s/^-//) {
      my ($op, @stuff) = grep length,
                         split /([:+^=%\/]?[a-zA-Z]|[-+\.0-9]+)/, $o;
      die "undefined short op: $op" unless exists $op_shorthand_lookups{$op};
      $op = $op_shorthand_lookups{$op} =~ s/^--//r;

      # Short options expand like this:
      #
      #   -sf10m 'foo'
      #   -s -f 10 -m 'foo'
      #
      # Doing this involves knowing whether each thing is a command (in which
      # case it gets a - prefix), or an argument. To do this, we expand
      # everything out into un-prefixed things, prepend it to the remaining
      # arguments (in case the command wants more arguments than were packed
      # into the short form), and see whether the command consumes all of the
      # short stuff.
      my ($args, @rest) = apply_format $op_formats{$op}, @stuff, @_;
      push @parsed, [$op, @$args];

      if (@rest > @_) {
        # The op left some packed-short stuff behind, so the next thing is a
        # command. We need to repack everything because otherwise we'd end up
        # losing track of deeply-stacked short commands.
        my @to_repack = @rest[0 .. $#rest - @_];
        @_ = ('-' . join('', @to_repack), @rest[@rest - @_ .. $#rest]);
      } else {
        # Nothing left behind, so just keep going normally.
        @_ = @rest;
      }
    } else {
      push @parsed, file_opt $o;
    }
  }
  @parsed;
}
