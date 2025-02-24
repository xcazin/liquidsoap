#!../../src/liquidsoap ../../libs/stdlib.liq

success = ref(true)

%include "test.liq"

def t(x, y)
  if x != y then
    print("Failure: got #{x} instead of #{y}")
    success := false
  end
end

def f() =
  # Basic checks
  n = 2
  r = n.{ a = 8 , b = 12 , f = fun(x) -> 2 * x }
  t(1+r, 3)
  t(r.b, 12)
  t(r.a, 8)
  t(r.f(5), 10)
  #TODO: the following fails because it gets parsed as the float 2. followed by the record {a = 5}...
  #r = 2.{a = 5}

  # Test overriding with subfields
  r = ()
  let r.f = ()
  let r.f.variant = 7
  let r.f = r.f.variant
  ignore(r)

  # Test replacing subfields
  r = ()
  let r.a = ()
  let r.a.b = 5
  let replaces r.a = 2
  ignore(r.a.b)
  def replaces r.a (x) = 2*x end
  ignore(r.a.b)

  # A resettable counter
  n = ref(0)
  def counter()
    n := !n + 1
    !n
  end
  def counter.reset()
    n := 0
  end

  ignore(counter())
  ignore(counter())
  t(counter(), 3)
  counter.reset()
  t(counter(), 1)

  # Float / field disambiguation
  r = 3.{s = "a"}
  _ = r.s

  # Open
  r = ()
  def r.f(n) = 2*n end
  open r
  t(f(3), 6)

  # Test subtyping in lists
  a = "a"
  b = "b"
  let a.x = 5
  let b.x = 3
  let b.y = 1.
  l = [a,b]
  ignore(list.hd(l).x)
  l = [b,a]
  ignore(list.hd(l).x)
  def f(c) = [a,c] end

  # Subsequent increase of the type
  _ = if true then {a = 4, b = 5} else {a = 4} end
  _ = if true then {a = 4} else {a = 4, b = 5} end

  # Equality
  t({a = 5} == {a = 5}, true)
  t({a = 5} == {a = 6}, false)
  #t({a = 5, b = 3} == {a = 6}, false) # Type inference is not smart enough for this one for now
  t({a = 5} == {a = 6, b = 4}, false)
  t([{a = 5}] == [{a = 5}], true)
  t(({a = 5}) == ({a = 5}), true)

  if !success then test.pass() else test.fail() end
end

test.check(f)
