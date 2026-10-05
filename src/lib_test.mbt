///|
test "fib" {
  let array = [1, 2, 3, 4, 5].map(@bitflow.fib)

  // `inspect` is used to check the output of the function
  // Just write `inspect(value)` and execute `moon test --update`
  // to update the expected output, and verify them afterwards
  @debug.debug_inspect(array, content="[1, 2, 3, 5, 8]")
}

///|
test "sum" {
  let array = [1, 2, 3, 4, 5]
  inspect(@bitflow.sum(data=array), content="15")
  inspect(@bitflow.sum(data=array, start=1), content="14")
  inspect(@bitflow.sum(data=array, length=3), content="6")
  let length = None
  // Use `?` for punning
  inspect(@bitflow.sum(data=array, length?), content="15")
}
