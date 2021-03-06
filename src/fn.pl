# Function compilation stuff
# How a function gets compiled ends up depending on things like the type of its
# input and whether we need it to be an actual function, or whether the code
# can be inlined. This file contains definitions that handle this stuff.

use List::Util qw/max/;
use List::MoreUtils qw/any none firstidx/;

# Functions are compiled using various namespaces selected based on the first
# character of the function (this turns out to be really useful later on):
our %fn_namespaces;

# ... and Perl functions are run through the following filters, in order:
our @perl_source_filters;

sub compile_perl_lambda;
sub fn {
  my ($code, $type) = @_;
  return with_type $type, gen('fn:F', {f => $code}, q{ %:f->(@_) })
    if ref $code eq 'CODE';

  my $prefix = substr $code, 0, 1;
  return $fn_namespaces{$prefix}->($code, $type)
    if exists $fn_namespaces{$prefix};
  compile_perl_lambda @_;
}

sub deffnns {
  my ($prefix, $compiler) = @_;
  die "deffnns: prefix must be exactly one character (got '$prefix')"
    unless length $prefix == 1;
  die "deffnns: cannot redefine existing function namespace '$prefix'"
    if exists $fn_namespaces{$prefix};

  die "deffnns: declining to usurp '$prefix', which is useful in code"
    if $prefix =~ /^[-\s+~\/'"_\.0-9a-z\$\@\%(\[{]/;

  $fn_namespaces{$prefix} = $compiler;
}

sub defperlfilter {
  my ($name, $filter, $after) = @_;
  die "defperlfilter: a filter called $name already exists"
    if any {$$_[0] eq $name} @perl_source_filters;

  die "defperlfilter: $after is not a defined filter"
    if defined $after and none {$$_[0] eq $name} @perl_source_filters;

  if (defined $after) {
    splice @perl_source_filters,
           1 + (firstidx {$$_[0] eq $name} @perl_source_filters),
           0,
           [$name, $filter];
  } else {
    push @perl_source_filters, [$name, $filter];
  }
}

# Default compiler: perl with %N aliased to field values and dot-style hash
# dereferencing to make JSON easier.
sub compile_perl_lambda {
  my ($code, $type) = @_;
  my ($original_code, $original_type) = ($code, $type);

  if (defined $type) {
    ($code, $type) = $$_[1]->($code, $type) for @perl_source_filters;
    (gen({description => $original_code}, {}, $code), $type);
  } else {
    # Generate a proper Perl function with arguments in @_
    $type = 'F';
    ($code, $type) = $$_[1]->($code, $type) for @perl_source_filters;
DEBUG
    die "FIXME: $original_code started as type F and ended as $code "
      . "with type $type" unless $type eq 'F';
DEBUG_END
    my $f = eval "sub {\n$code\n}";
    die "fn: failed to compile '$original_code' -> '$code': $@"
      if $@;
    $f;
  }
}

defperlfilter 'expand_json_dot_notation', sub {
  my ($code, $type) = @_;
  1 while $code =~ s/([a-zA-Z\)\}\]])
                     \.
                     ([\$_a-zA-Z](?:-?[0-9\w\?\$])*)
                    /$1\->{'$2'}/x;
  ($code, $type);
};

defperlfilter 'expand_field_references_typefully', sub {
  my ($code, $type) = @_;

  # Does the function refer to any arguments? If so, force a field-split.
  # Otherwise we can get away with just providing $_.
  $type = 'F' if $code =~ /\@_/ || $code =~ /\$_\[/ || $code =~ /%\d+/;

  # Generate positional parameter references into @_.
  ($code =~ s/%(\d+)/\$_[$1]/gr, $type);
};
