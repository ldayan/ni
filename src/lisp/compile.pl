# ni lisp compiler
# This doesn't compile to final forms; instead, it compiles each form down to
# an internal representation that can be handed off to a JIT backend for
# optimized execution.

{

package ni::lisp;

# Special forms:
#
# (fn* name formal body)
# (co* alternatives...)
# (do* stuff...)
# (if* value then else)
#
# Toplevel forms are implicitly wrapped in a (do*) block to provide full
# side-effect ordering.
#
# Here's how each type of form impacts ordering in general:
#
# (f x y z)      <- f, x, y, and z are unordered relative to one another
# (let* k v f)   <- v happens before f
# ((fn* ...b) x) <- x happens before b
# (do* x y z)    <- x happens before y happens before z
# (co* x y z)    <- x, y, z unordered
# (if* v t e)    <- v happens before t or e; t or e doesn't happen at all
#
# The value of a (co*) form is a list of the result of each subexpression; as a
# result, we can say this:
#
# (f x y z) = (call* (co* f x y z))
#
# In theory you could (apply* f 5) or some such, but apply* isn't provided as a
# special form. This way you can always assume a function's arguments are
# specified in a list.

sub resolve_scope {
  my ($scope, $x) = @_;
  return undef unless ref $scope eq 'HASH';
  $$scope{$x} // resolve_scope($$scope{''}, $x);
}

deftypemethod 'is_special_operator',
  symbol => sub {
    my ($self) = @_;
    $$self if $$self eq 'fn*' || $$self eq 'let*'
           || $$self eq 'do*' || $$self eq 'co*' || $$self eq 'if*';
  };

deftypemethod 'usable_as_formal',
  symbol => sub { 1 };

# Graph encoding
# Graphs are doubly-linked structures with directed edges indicating
# continuations. Each node represents a processing step -- possibly a no-op --
# and, if it is marked as side-effecting, constrains execution ordering.

our %special_to_graph = (
  'fn*' => sub {
    # Create a new graph link for the function's formal and self-reference and
    # add both to a new scope. We want to represent the function as a
    # disconnected graph here, adding it as a value to the surrounding graph.
    my ($scope, $self_ref, $formal, $body) = @_;
    die "fn* self ref must be a symbol (got $self_ref instead)"
      unless $self_ref->usable_as_formal;
    die "fn* formal must be a symbol (got $formal instead)"
      unless $formal->usable_as_formal;

    fn_node $self_ref, $formal, $body;
  },

  'let*' => sub {
    # This one is easy: just create a subscope that aliases the given name.
    # Also make sure that we force side-effect ordering in value before body.
    my ($scope, $name, $value, $body) = @_;
    die "let* formal must be a symbol (got $name instead)"
      unless $name->usable_as_formal;
    my $v = $value->to_graph($scope);
    $v->then($body->to_graph({'' => $scope, $$name => $v}));
  },

  'do*' => sub {
    # Create a series of nodes, linking each as the continuation of the
    # previous one.
    my ($scope, $first, @others) = @_;
    $first = $first->then($_) for @others;
    $first;
  },

  'co*' => sub {
    # Create a single-in, single-out node that semantically returns a list.
    my ($scope, @nodes) = @_;
    co_node map $_->to_graph($scope), @nodes;
  },

  'if*' => sub {
    my ($scope, $cond, $then, $else) = @_;
    if_node $cond->to_graph($scope),
            $then->to_graph($scope),
            $else->to_graph($scope);
  },

  'apply*' => sub {
    my ($scope, @args) = @_;
    apply_node map $_->to_graph($scope), @args;
  },
);

deftypemethod 'to_graph',
  list => sub {
    my ($self, $scope) = @_;
    my ($head, @rest) = @$self;
    my $special = $head->is_special_operator;
    $special ? $special_to_graph{$special}->($scope, @rest)
             : $special_to_graph{'apply*'}->($scope, $head, @rest);
  },

  array => sub {
    my ($self, $scope) = @_;
    bless_node 'array', co_node map $_->to_graph($scope), @$self;
  },

  hash => sub {
    my ($self, $scope) = @_;
    bless_node 'hash', co_node map $_->to_graph($scope), @$self;
  },

  str => sub {
    # TODO: handle escape sequences
    literal_node 'string', ${$_[0]};
  },

  qstr => sub {
    # TODO: handle escape sequences
    literal_node 'string', ${$_[0]};
  },

  number => sub {
    literal_node 'number', ${$_[0]};
  },

  symbol => sub {
    my ($self, $scope) = @_;
    resolve($scope, $$self) // global_node($$self);
  };

}
