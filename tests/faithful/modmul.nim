import std/syncio
# intermediate products exceed 2^53, so fast mode (number) loses precision.
var m: int64 = 998244353'i64
var d: int64 = 1'i64
var base: int64 = 123456789'i64
for i in 0..<50:
  d = d * base mod m
echo d
var big: int64 = 3037000500'i64          # ~sqrt(2^63); big*big overflows int64
echo big * big
