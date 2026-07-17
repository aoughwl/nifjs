## nifjs_cli — transpile a .s.nif file to JavaScript on stdout.
when defined(nimony):
  {.feature: "lenientnils".}
import std/[syncio, os]
import nifcursors, programs
import emitjs

proc main =
  var path = ""
  var faithful = false
  let params = commandLineParams()
  for p in params:
    if p == "--faithful":
      faithful = true
    elif p.len > 0 and p[0] != '-' and path.len == 0:
      path = p
  if path.len == 0:
    write stderr, "aifjs: usage: aifjs [--faithful] <module.s.nif>\n"
    quit 2
  var src = ""
  try:
    src = readFile(path)
  except:
    write stderr, "aifjs: cannot read file\n"
    quit 1
  setFaithful(faithful)
  setupProgramForTesting("", "cli", ".s.nif")
  var buf = parseFromBuffer(src, "cli")
  var root = beginRead(buf)
  write stdout, emitModule(root)

main()
