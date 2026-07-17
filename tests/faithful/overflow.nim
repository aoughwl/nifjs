import std/syncio
var a: int64 = 9223372036854775807'i64   # INT64_MAX
echo a
var b: int64 = a + 1'i64                  # wraps to INT64_MIN faithfully
echo b
var c: int = 1000000007
var d: int = 0
for i in 0..<40:
  d = d * c mod 998244353
echo d
var u: uint64 = 18446744073709551615'u64 # UINT64_MAX
echo u
