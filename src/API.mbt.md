# API Documentation

This file contains executable doc tests using `mbt test` blocks.

## fib

Calculate the n-th Fibonacci number.

```mbt check
///|
test {
  inspect(@bitflow.fib(0), content="1")
  inspect(@bitflow.fib(1), content="1")
  inspect(@bitflow.fib(10), content="89")
}
```

## sum

Sum elements in an array with optional start index and length.

```mbt check
///|
test {
  let data = [1, 2, 3, 4, 5]
  inspect(@bitflow.sum(data~), content="15")
  inspect(@bitflow.sum(data~, start=2), content="12")
  inspect(@bitflow.sum(data~, length=3), content="6")
}
```
