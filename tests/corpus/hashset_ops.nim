import std/syncio
import std/sets

# std/sets HashSet -> native JS Set: initHashSet/incl/excl/contains(`in`)/len.
proc main {.raises: [].} =
  var s = initHashSet[int]()
  s.incl(3); s.incl(7); s.incl(3)   # duplicate is a no-op
  echo s.len       # 2
  echo (7 in s)    # true
  echo (4 in s)    # false
  s.excl(7)
  echo (7 in s)    # false
  echo s.len       # 1
main()
