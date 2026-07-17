import std/syncio
var a: int64 = 1000000000000000003'i64
var b: int64 = 7'i64
echo a div b
echo a mod b
echo (0'i64 - a) div b                    # truncates toward zero
echo (0'i64 - a) mod b                    # sign follows dividend
var u: uint64 = 18000000000000000000'u64
echo u div 7'u64
echo u mod 7'u64
