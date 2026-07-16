## emitjs.nim — the nifjs emitter: walk a typed `.s.nif` `Cursor` and append the
## equivalent JavaScript to a buffer. This is `nifi`'s interpreter dispatch with
## every "run it" replaced by "print it", so it reuses nifi's tested front-end
## (nifcursors + the tag model + symbol pool) and adds only the codegen.
##
## STATUS: seed / WIP. The dispatch skeleton and the core handlers are here; the
## fuller coverage (objects/variants/sets/generics/var-params/shims) is being
## ported over from the JS reference implementation (aoughwl/nifjs-js), which is
## already language-complete for what nimony can express.
##
## Built alongside a nifi checkout (it shares nifi's front-end modules). Mirrors
## the imports of nifi/src/nifi/interp.nim.

import std/[strutils, tables, sets]
import nifcursors
import ".." / ".." / "nifi" / src / nifi / [values, programs]   # nifi front-end
import ".." / ".." / "nimony" / src / models / tags             # StmtsTagId, IfTagId, …

type
  JsEmitter* = object
    js*: string                 ## the JavaScript output buffer
    defined*: HashSet[string]    ## every proc/func mangled name (for call resolution)
    boxed*: HashSet[string]      ## current proc's `var`/`out` params (accessed as `.v`)

proc emit(e: var JsEmitter; s: string) = e.js.add s

## `sym.0.mod` -> a valid, stable JS identifier (mirrors nifjs-js `mangle`).
proc mangle(name: string): string =
  result = "v_"
  for ch in name:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: result.add ch
    else: result.add '_'

## the bare callee/operator name — everything before the first `.<digit>`
## disambiguator (the name itself may contain dots, e.g. `..<`).
proc opName(name: string): string =
  for i in 0 ..< name.len - 1:
    if name[i] == '.' and name[i+1] in {'0'..'9'}:
      return name[0 ..< i]
  result = name.strip(leading = false, chars = {'.'})

# ---------------------------------------------------------------------------
# forward decls (same shape as interp.nim)
# ---------------------------------------------------------------------------
proc emitStmt(e: var JsEmitter; n: var Cursor)
proc emitStmts(e: var JsEmitter; n: var Cursor)
proc emitExpr(e: var JsEmitter; n: var Cursor)

proc emitStmts(e: var JsEmitter; n: var Cursor) =
  ## (stmts S0 S1 …)
  inc n                          # past the `stmts` tag
  while n.kind != ParRi:
    emitStmt(e, n)
  consumeParRi n

proc emitIf(e: var JsEmitter; n: var Cursor) =
  ## (if (elif COND BODY) … (else BODY)?)
  inc n
  var first = true
  while n.kind != ParRi:
    if n.tagEnum == ElifTagId:
      inc n
      e.emit(if first: "if(" else: " else if(")
      emitExpr(e, n); e.emit("){\n")
      emitStmt(e, n); e.emit("\n}")
      consumeParRi n
      first = false
    elif n.tagEnum == ElseTagId:
      inc n
      e.emit(" else {\n"); emitStmt(e, n); e.emit("\n}")
      consumeParRi n
    else:
      skip n
  consumeParRi n

proc emitWhile(e: var JsEmitter; n: var Cursor) =
  inc n
  e.emit("while("); emitExpr(e, n); e.emit("){\n")
  emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitRet(e: var JsEmitter; n: var Cursor) =
  inc n
  if n.kind == ParRi: e.emit("return;")
  else: (e.emit("return "); emitExpr(e, n); e.emit(";"))
  consumeParRi n

proc emitStmt(e: var JsEmitter; n: var Cursor) =
  if n.kind != ParLe:
    inc n
    return
  case n.tagEnum
  of StmtsTagId:       emitStmts(e, n)
  of IfTagId:          emitIf(e, n)
  of WhileTagId:       emitWhile(e, n)
  of RetTagId:         emitRet(e, n)
  # of VarTagId, LetTagId, ConstTagId, GvarTagId: emitLocal(e, n)   # TODO
  # of AsgnTagId:      emitAsgn(e, n)                                # TODO
  # of CallTagId, CmdTagId: (emitExpr(e, n); e.emit(";"))            # TODO
  else:
    skip n              # unsupported: skip (TODO: raise so gaps are visible)

proc emitExpr(e: var JsEmitter; n: var Cursor) =
  ## TODO: port from nifjs-js emitExpr — arithmetic (with 32-bit wrapping),
  ## comparisons, calls, literals, symbols, case/if-expr, seq/obj/tuple, sets.
  skip n

# ---------------------------------------------------------------------------
# entry: walk a loaded module root, return the emitted JS.
# ---------------------------------------------------------------------------
proc emitModule*(root: var Cursor): string =
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  # TODO: two-pass — collect proc/func names into e.defined, emit each routine,
  # then emit top-level at module scope; return __out. (See nifjs-js emitModule.)
  emitStmt(e, root)
  e.emit("\nreturn __out;\n")
  result = e.js
