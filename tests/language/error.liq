#!../../src/liquidsoap ../../libs/stdlib.liq ../../libs/deprecations.liq

%include "test.liq"

success = ref(true)

def t(x, y)
  if x != y then
    print("Failure: got #{x} instead of #{y}")
    success := false
  end
end
  
def f() =
  # Works as expected with no errors
  ret = try
    4
  catch _ do
    5
  end

  t(ret, 4)

  e = error.register("foo")
  t(e, error.register("foo"))

  # Works as expected with no errors
  ret = try
    4
  catch _ : [e] do
    5
  end

  t(ret, 4)

  # Can report kind
  ret = try
    error.raise(e);
    "bla"
  catch err do
    err.kind
  end 
  t(ret, "foo")

  # Can report empty message
  ret = try
    error.raise(e)
    "bla"
  catch err do
    err.message
  end
  t(ret, "")

  # Can report set message
  ret = try
    error.raise(e, "msg");
    "bla"
  catch err do
    err.message ?? "blo"
  end
  t(ret, "msg")

  e' = error.register("bla")
  t(false, (e == e'))

  # Ignores errors when not in list
  ret =
    try
      try
        error.raise(e, "msg");
        "bla"
      catch _ : [e'] do
        "blo"
      end
    catch _ : [e] do
      "gni"
    end
  t(ret, "gni")

  # Ignore errors when list is empty
  ret =
    try
      try
        error.raise(e, "msg");
        "bla"
      catch _ : [] do
        "blo"
      end
    catch _ : [e] do
      "gni"
    end
  t(ret, "gni")

  # Catches error when in list
  ret =
    try
      try
        error.raise(e, "msg");
        "bla"
      catch _ : [e, e'] do
        "blo"
      end
    catch _ : [e] do
      "gni"
    end
  t(ret, "blo")

  def on_done() =
    if !success then
      test.pass()
    else
      test.fail()
    end 
  end

  # Catches error
  def on_error(~backtrace, ~thread_name, e) =
    print("caught error #{e} from thread #{thread_name} and backtrace:\n#{backtrace}")
    if e.kind == "foo" then
      on_done()
    else
      test.fail()
    end
  end

  thread.on_error(e, on_error)
  thread.run(fun () -> error.raise(e, "Asynchronous error"))
end

test.check(f)
