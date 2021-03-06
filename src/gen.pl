# Code generator
# This exists because I want gensyms and external references to be easier to
# deal with. It also supports some nice stuff like insertion points and
# peephole optimizations.

BEGIN {

sub ni::gen::new;
sub gen       { local $_; ni::gen->new(@_) }
sub gen_empty { gen('empty', {}, '') }

sub gen_seq {
  # Generates an imperative sequence of statements.
  my ($name, @statements) = @_;
  my $code_template = join "\n", map "%\@x$_;", 0 .. $#statements;
  my %subst;
  $subst{"x$_"} = $statements[$_] for 0 .. $#statements;
  gen $name, {%subst}, $code_template;
}

{

package ni::gen;

use overload qw# %  subst  * map  @{} inserted_code_keys  "" compile
                 eq compile_equals #;

our $gensym_id = 0;
sub gensym { '$_' . ($_[0] // '') . '_' . $gensym_id++ . '__gensym' }

DEBUG
use Carp;
our $gen_id = 0;
DEBUG_END

sub parse_signature {
  return $_[0] if ref $_[0];
  my ($first, @stuff) = split /\s*;\s*/, $_[0];
  my ($desc, $type)   = split /\s*:\s*/, $first;
  my $result = {description => $desc,
                type        => $type};

  /^(\S+)\s*=\s*(.*)$/ and $$result{$1} = $2 for @stuff;
  $result;
}

sub parse_code;
sub new {
  my ($class, $sig, $refs, $code) = @_;
  my ($fragments, $gensym_indexes, $insertions) =
    parse_code($code =~ s/^\s*|\s*$//gr);

  # Substitutions can be specified as refs, in which case we pull them out and
  # do a rewrite automatically (this is more notationally expedient than having
  # to do a % operation right away).
  my %subst;
  for (keys %$refs) {
    if (exists $$insertions{$_}) {
      $subst{$_} = $$refs{$_};
      delete $$refs{$_};
    }
  }

DEBUG
  exists $$gensym_indexes{$_} or confess "unknown ref $_ in $code"
    for keys %$refs;
  exists $$refs{$_} or confess "unused ref $_ in $code"
    for keys %$gensym_indexes;
DEBUG_END

  # NB: must use some kind of copying operator like % here, since parse_code is
  # memoized.
  bless({ sig               => parse_signature($sig),
DEBUG
          id                => ++$gen_id,
DEBUG_END
          fragments         => $fragments,
          gensym_names      => {map {$_, undef} keys %$gensym_indexes},
          gensym_indexes    => $gensym_indexes,
          insertion_indexes => $insertions,
          refs              => $refs // {} },
        $class) % {%subst};
}

sub copy {
  my ($self) = @_;
  my %new = %$self;
DEBUG
  $new{id}           = ++$gen_id;
DEBUG_END
  $new{sig}          = {%{$new{sig}}};
  $new{fragments}    = [@{$new{fragments}}];
  $new{gensym_names} = {%{$new{gensym_names}}};

  bless(\%new, ref $self)->replace_gensyms(
    {map {$_, gensym $_} keys %{$new{gensym_names}}});
}

sub replace_gensyms {
  my ($self, $replacements) = @_;
  for (keys %$replacements) {
    if (exists $$self{gensym_names}{$_}) {
      my $is = $$self{gensym_indexes}{$_};
      my $g  = $$self{gensym_names}{$_} = $$replacements{$_};
      $$self{fragments}[$_] = $g for @$is;
    }
  }
  $self;
}

sub genify {
  return $_[0] if ref $_[0] && $_[0]->isa('ni::gen');
  return ni::gen('genified', {}, $_[0]);
}

sub compile_equals {
  my ($self, $x) = @_;
  $x = $x->compile if ref $x;
  $self->compile eq $x;
}

sub share_gensyms_with {
  # Any intersecting gensyms from $g will be renamed to align with $self.
  # This directionality matters so multiple calls against $self will form a set
  # of mutually gensym-shared fragments.
  my ($self, $g) = @_;
  $g->replace_gensyms($$self{gensym_names});
  $self;
}

sub inherit_gensyms_from {
  $_[1]->share_gensyms_with($_[0]);
  $_[0];
}

sub build_ref_hash {
  my ($self, $refs) = @_;
  $refs //= {};
  $$refs{$$self{gensym_names}{$_}} = $$self{refs}{$_} for keys %{$$self{refs}};
  $$self{fragments}[$$self{insertion_indexes}{$_}[0]]->build_ref_hash($refs)
    for @$self;
  $refs;
}

sub inserted_code_keys {
  my ($self) = @_;
  [sort keys %{$$self{insertion_indexes}}];
}

sub subst_in_place {
  my ($self, $vars) = @_;
  for my $k (keys %$vars) {
    my $is = $$self{insertion_indexes}{$k};
DEBUG
    confess "unknown subst var: $k (code is $self)" unless defined $is;
DEBUG_END
    my $f = genify $$vars{$k};
    $$self{fragments}[$_] = $f for @$is;
  }
  $self;
}

sub subst {
  my ($self, $vars) = @_;
  $self->copy->subst_in_place($vars);
}

sub map {
  my ($self, $f) = @_;
  $f = ni::compile $f;
  my $y = &$f($self);
  return $y unless $y eq $self;

  # If we haven't changed, then operate independently on the
  # already-substituted code fragments and build a new instance.
  my $new = bless {}, ref $self;
  $$new{$_} = $$self{$_} for keys %$self;
  $$new{fragments} = [@{$$new{fragments}}];

  $new % {map {$_, $$new{fragments}[$$new{insertion_indexes}{$_}] * $f} @$new};
}

DEBUG
sub debug_to_string {
  # Don't use this to compile; use ->compile() instead.
  my ($self) = @_;
  my $refs = $self->build_ref_hash;

  my $code_string = join '',
    map ref $_ eq 'ARRAY'   ? "<UNBOUND: $$_[0]>"
      : ref $_ eq 'ni::gen' ? $_->debug_to_string
                            : $_,
        @{$$self{fragments}};

  my $ref_string = join ', ', map "$_: $$refs{$_}", sort keys %$refs;
  my $sig_string = join ', ', map "$_: $$self{sig}{$_}",
                                  sort keys %{$$self{sig}};
  "[$$self{id} {$sig_string} {$ref_string}\n$code_string]";
}
DEBUG_END

sub compile {
  my ($self) = @_;
DEBUG
  ref $_ eq 'ARRAY' && confess "cannot compile underdetermined gen $self"
    for @{$$self{fragments}};
DEBUG_END
  join '', @{$$self{fragments}};
}

sub lexical_definitions {
  my ($self, $refs) = @_;
  $refs //= $self->build_ref_hash;
  ni::gen "lexicals", {},
    join "\n", map sprintf("my %s = \$_[0]->{'%s'};", $_, $_), keys %$refs;
}

sub compile_to_sub {
  my ($self) = @_;
  my $code     = $self->compile;
  my $refs     = $self->build_ref_hash;
  my $bindings = $self->lexical_definitions($refs);
  my $f        = eval($code = "package main; sub {\n$bindings\n$code\n}");
  die "$@ compiling\n$code" if $@;
  ($f, $refs);
}

sub run {
  my ($self) = @_;
  my ($f, $refs) = $self->compile_to_sub;
  my @result = &$f($refs);
  delete $$refs{$_} for keys %$refs;    # we create circular refs sometimes
  @result;
}

our %parsed_code_cache;
sub parse_code {
  # Returns ([@code_fragments], {gensym_indexes}, {insertion_indexes})
  my ($code) = @_;
  my $cached;
  unless (defined($cached = $parsed_code_cache{$code})) {
    my @pieces = grep length, split /(\%:\w+|\%\@\w+)/,
                                    $code =~ s/(\%\@\w+)/\n$1\n/gr;
    my @fragments;
    my %gensym_indexes;
    my %insertion_indexes;
    for (0 .. $#pieces) {
      if ($pieces[$_] =~ /^\%:(\w+)$/) {
        push @{$gensym_indexes{$1} //= []}, $_;
        push @fragments, undef;
      } elsif ($pieces[$_] =~ /^\%\@(\w+)$/) {
        push @{$insertion_indexes{$1} //= []}, $_;
        push @fragments, [$1];
      } else {
        push @fragments, $pieces[$_];
      }
    }
    $cached = $parsed_code_cache{$code} = [[@fragments],
                                           {%gensym_indexes},
                                           {%insertion_indexes}];
  }
  @$cached;
}

}

}
