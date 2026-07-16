## webmain_js.nim — the browser entry for nifjs, mirroring nifi/src/nifi/webmain.nim.
## The JS glue parks a `.s.nif` string on `globalThis.__nifi_src`; we parse it in
## memory, walk it with the emitter, and hand the produced JavaScript back on
## `globalThis.__njs_out`. No file I/O — the same shape as nifi's web entry.
##
## STATUS: seed / WIP (see emitjs.nim).

when defined(nimony):
  {.feature: "lenientnils".}

import nifcursors
import ".." / ".." / "nifi" / src / nifi / programs
import emitjs
import jsffi

proc compileToJs(src: string): string =
  ## Parse `.s.nif` bytes from memory and emit native JavaScript for them.
  setupProgramForTesting("", "webmod", ".s.nif")
  var buf = parseFromBuffer(src, "webmod")
  var root = beginRead(buf)
  result = emitModule(root)

proc njsRun() =
  ## Module-init entry (NOT `{.exportc:"main".}` — see nifi's webmain note).
  let src = global("__nifi_src").toStr
  let js = compileToJs(src)
  let g = global("globalThis")
  g.set("__njs_out", toJs(js))

njsRun()
