## emitjs.nim — the aifjs emitter: walk a typed `.s.nif` `Cursor` and append the
## equivalent JavaScript. This is `aifi`'s interpreter dispatch with every "run
## it" replaced by "print it", reusing aifi's front-end (nifcursors + the tag
## model + the literal pool).
##
## Built with the aifi build paths (see webtest_js.sh):
##   -p:nimony/src/{lib,nimony,models,gear2}  -p:aifi/src/nifi
##
## STATUS: the computational core compiles + transpiles end-to-end (procs,
## params/result, var/let/const, asgn, if/elif/else, while, ret, arithmetic &
## comparisons with calls, echo, int/string/char literals). The fuller coverage
## (seq/obj/tuple/set/case/generics/var-params/shims) is being ported from the
## JS reference impl (aoughwl/aifjs-js), which is already language-complete.
##
## EXPORT MODES: the default "fast" mode maps every nimony int to JS `number`
## (readable, but silently lossy past 2^53). The opt-in `--faithful` mode maps
## width-64 ints (`int`/`int64`/`uint`/`uint64`) to native `bigint` and
## width-wraps 64-bit arithmetic (`BigInt.asIntN/asUintN`), so int64/uint64 values
## and overflow stay numerically exact. Faithful mode is strictly additive: with
## `faithfulMode == false` every code path below is byte-for-byte the original.

when defined(nimony):
  {.feature: "lenientnils".}

import std/[strutils, sets, tables]
import nifcursors, nifstreams, nimony_model
import tags
import aowlhl/hlwalk   # shared HL-IR shape decoders (local/param/proc/if/case)

type
  JsEmitter = object
    js: string

## enum value (mangled) -> its ordinal, filled by scanEnums before emission.
## (parallel seqs, not a Table: nimony's Table `[]=` is `.raises`.)
var enumKeys: seq[string] = @[]
var enumVals: seq[string] = @[]
proc enumLookup(nm: string): string =
  for i in 0 ..< enumKeys.len:
    if enumKeys[i] == nm: return enumVals[i]
  return ""

## var/out-param boxing (ported from the JS impl). A `var`/`out` param is passed
## by reference, but JS primitives pass by value — so a boxed param is passed as
## an accessor object `{get v(){…}, set v(x){…}}` closing over the caller's lval,
## and inside the callee every `(hderef p)`/`(haddr p)` reads/writes `p.v`.
## `boxProcNames[i]` -> comma-wrapped boxed arg indices (",0,2,"), filled by
## scanProcBoxed. `curBoxed` = the boxed param names of the routine being emitted.
var boxProcNames: seq[string] = @[]
var boxProcIdx: seq[string] = @[]
var curBoxed: seq[string] = @[]
proc boxLookup(nm: string): string =
  for i in 0 ..< boxProcNames.len:
    if boxProcNames[i] == nm: return boxProcIdx[i]
  return ""
proc boxContains(nm: string): bool =
  for b in curBoxed:
    if b == nm: return true
  return false

proc emit(e: var JsEmitter; s: string) = e.js.add s

## faithful-export mode (opt-in via the CLI `--faithful` flag). In faithful mode
## width-64 integer types map to JS `bigint` and 64-bit arithmetic is width-wrapped
## with `BigInt.asIntN/asUintN`, so values past 2^53 (and int64/uint64 overflow)
## stay numerically exact. Default false keeps the original all-`number` fast mode
## byte-for-byte — faithful mode is a strictly additive, opt-in path.
var faithfulMode: bool = false
proc setFaithful*(b: bool) = faithfulMode = b
proc isFaithful*(): bool = faithfulMode

## names (mangled) of locals/params that hold a `bigint` in faithful mode — lets
## assignment RHS / conv coercions / return values know when a leaf must be bigint
## (with the `n` suffix) rather than a plain `number`.
var bigVars: seq[string] = @[]
proc bigContains(nm: string): bool =
  for b in bigVars:
    if b == nm: return true
  return false
proc bigAdd(nm: string) =
  if not bigContains(nm): bigVars.add nm

## true iff the proc currently being emitted returns a 64-bit int (faithful mode);
## a bare-literal `return` in such a proc must emit bigint.
var curRetBig: bool = false

## a nimony symbol -> a stable, valid JS identifier.
proc mangle(name: string): string =
  result = "v_"
  for ch in name:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: result.add ch
    else: result.add '_'

## bare callee/operator name — everything before the first `.<digit>`.
proc opName(name: string): string =
  var i = 0
  while i + 1 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}: return name[0 ..< i]
    inc i
  result = name.strip(leading = false, chars = {'.'})

proc jsString(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else: result.add ch
  result.add "\""

# forward decls (same shape as interp.nim)
proc emitStmt(e: var JsEmitter; n: var Cursor)
proc emitExpr(e: var JsEmitter; n: var Cursor; wantBig = false)
proc exprToStr(n: var Cursor; wantBig = false): string
proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool)
proc emitBoxArg(e: var JsEmitter; n: var Cursor)

## the JS operator for a binary-arithmetic/comparison tag, or "" if not one.
proc binOp(t: TagEnum): string =
  if t == AddTagId: " + "
  elif t == SubTagId: " - "
  elif t == MulTagId: " * "
  elif t == LtTagId: " < "
  elif t == LeTagId: " <= "
  elif t == EqTagId: " === "
  elif t == NeqTagId: " !== "
  elif t == BitandTagId: " & "
  elif t == BitorTagId: " | "
  elif t == BitxorTagId: " ^ "
  elif t == ShlTagId: " << "
  elif t == ShrTagId: " >> "
  elif t == AshrTagId: " >> "
  else: ""

proc isCallTag(t: TagEnum): bool =
  t == CallTagId or t == CmdTagId or t == InfixTagId or t == PrefixTagId or t == HcallTagId

## best-effort "is this echoed value a float?" (peeks a Cursor copy) — a float
## literal, an arithmetic op with a `(f …)` result type, or a float-returning
## math call. Used only to keep integer-valued floats printing as `7.0`, not `7`.
proc looksFloat(c: Cursor): bool =
  if c.kind == FloatLit: return true
  if c.kind != ParLe: return false
  let t = c.tagEnum
  if t == AddTagId or t == SubTagId or t == MulTagId or t == DivTagId:
    var d = c; inc d
    return d.kind == ParLe and d.tagEnum == FTagId
  if t == CallTagId or t == HcallTagId:
    var d = c; inc d
    let callee = if d.kind == Symbol or d.kind == SymbolDef: pool.syms[d.symId] else: ""
    let nm = opName(callee)
    return nm == "sqrt" or nm == "pow" or nm == "sin" or nm == "cos" or nm == "tan" or
           nm == "exp" or nm == "ln" or nm == "hypot" or nm == "floor" or nm == "ceil"
  return false

proc joinList(xs: seq[string]; sep: string): string =
  result = ""
  var first = true
  for x in xs:
    if not first: result.add sep
    first = false
    result.add x

## classify a nimony type node for faithful mode: 0 = not a 64-bit int type,
## 1 = signed 64-bit (int/int64), 2 = unsigned 64-bit (uint/uint64). Default `int`
## and `int64` both encode as `(i 64)`; `uint`/`uint64` as `(u 64)`.
proc int64Kind(c: Cursor): int =
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    if nm == "int" or nm == "int64" or nm == "Natural" or nm == "Positive": return 1
    elif nm == "uint" or nm == "uint64": return 2
    else: return 0
  of ParLe:
    let t = n.tagEnum
    if t == ITagId or t == UTagId:
      inc n
      if n.kind == IntLit and pool.integers[n.intId] == 64:
        return (if t == ITagId: 1 else: 2)
      return 0
    elif t == MutTagId or t == OutTagId or t == SinkTagId or t == LentTagId or
         t == RangetypeTagId:
      inc n
      return int64Kind(n)
    else: return 0
  else: return 0

## in faithful mode, does this expression already evaluate to a `bigint`? Used to
## decide conv coercions (bigint->number needs `Number(...)`) and asgn/return leaves.
proc producesBig(c: Cursor): bool =
  if not faithfulMode: return false
  var n = c
  case n.kind
  of Symbol, SymbolDef, Ident:
    return bigContains(mangle(pool.syms[n.symId]))
  of ParLe:
    let t = n.tagEnum
    if t == SufTagId:
      inc n; skip n                     # (suf LIT "suffix")
      if n.kind == StringLit:
        let s = pool.strings[n.litId]
        return s == "i64" or s == "u64"
      return false
    elif t == AddTagId or t == SubTagId or t == MulTagId or t == DivTagId or
         t == ModTagId or t == ShlTagId or t == ShrTagId or t == AshrTagId or
         t == BitandTagId or t == BitorTagId or t == BitxorTagId or t == NegTagId or
         t == ConvTagId or t == HconvTagId:
      inc n                             # arithmetic magics carry type as first child
      return int64Kind(n) > 0
    elif t == HderefTagId or t == HaddrTagId or t == ExprTagId:
      inc n
      return producesBig(n)
    else:
      return false
  else:
    return false

proc emitStmts(e: var JsEmitter; n: var Cursor) =
  inc n
  while n.kind != ParRi: emitStmt(e, n)
  consumeParRi n

proc emitBinop(e: var JsEmitter; n: var Cursor; op: string; t: TagEnum) =
  ## (op TYPE a b) -> (a op b). For 32-bit add/sub/mul, wrap on overflow
  ## (Math.imul / `| 0`) so hashing is exact; default 64-bit stays plain.
  inc n
  var imul = false
  var wrap32 = false
  var big64 = 0                   # 0=no, 1=signed, 2=unsigned (faithful mode)
  if n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId):
    var d = n; inc d
    let width = if d.kind == IntLit: pool.integers[d.intId] else: 0
    if width == 32 and (t == AddTagId or t == SubTagId or t == MulTagId):
      if t == MulTagId: imul = true else: wrap32 = true
    elif width == 64 and faithfulMode:
      big64 = if n.tagEnum == ITagId: 1 else: 2
  skip n                          # the type node
  if imul:
    e.emit("Math.imul("); emitExpr(e, n); e.emit(", "); emitExpr(e, n); e.emit(")")
  elif wrap32:
    e.emit("(("); emitExpr(e, n); e.emit(op); emitExpr(e, n); e.emit(") | 0)")
  elif big64 > 0:
    # operands must both be bigint; add/sub/mul/shl and the bitwise ops can exceed
    # the 64-bit range so wrap them, comparisons and >> stay bare.
    let needWrap = t == AddTagId or t == SubTagId or t == MulTagId or t == ShlTagId or
                   t == BitandTagId or t == BitorTagId or t == BitxorTagId
    let wrapper = if big64 == 1: "_i64" else: "_u64"
    if needWrap: e.emit(wrapper & "(") else: e.emit("(")
    emitExpr(e, n, true); e.emit(op); emitExpr(e, n, true)
    e.emit(")")
  else:
    e.emit("("); emitExpr(e, n); e.emit(op); emitExpr(e, n); e.emit(")")
  consumeParRi n

## emit an array index. In faithful mode an index may be a `bigint` (64-bit int),
## which JS rejects as an index, so coerce with `Number(...)` (a no-op for numbers).
proc emitIdx(e: var JsEmitter; n: var Cursor) =
  if faithfulMode:
    e.emit("Number("); emitExpr(e, n); e.emit(")")
  else:
    emitExpr(e, n)

proc emitBoxArg(e: var JsEmitter; n: var Cursor) =
  ## Box a var/out argument: (haddr LVAL) -> an accessor closing over the lval, so
  ## the callee's writes to `.v` land back on the caller's variable.
  var lv = ""
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
    lv = exprToStr(n)
    while n.kind != ParRi: skip n
    consumeParRi n
  else:
    lv = exprToStr(n)
  e.emit("{get v(){return " & lv & ";}, set v(_x){" & lv & " = _x;}}")

proc emitCall(e: var JsEmitter; n: var Cursor) =
  ## (call CALLEE ARGS…) / (cmd …). echo -> write(stdout,X) -> __w(X); the common
  ## seq/string builtins map to native JS; everything else is a plain call.
  inc n
  let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
  let name = opName(callee)
  if name == "write":
    skip n; skip n                # callee, stdout
    e.emit(if looksFloat(n): "__wf(" else: "__w(")
    emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "len":
    skip n; e.emit("("); emitExpr(e, n); e.emit(".length)")
    while n.kind != ParRi: skip n
  elif name == "[]":
    skip n; e.emit("("); emitExpr(e, n); e.emit("["); emitIdx(e, n); e.emit("])")
    while n.kind != ParRi: skip n
  elif name == "add":
    skip n
    let lv = exprToStr(n)                    # target: seq push, or string reassign
    e.emit("(" & lv & " = __append(" & lv & ", "); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "newSeq" or name == "newSeqUninit" or name == "newSeqOfCap" or
       name == "newSeqUninitialized":
    skip n                                   # seq constructors -> JS array
    if name == "newSeq" and n.kind != ParRi:
      e.emit("new Array("); emitExpr(e, n); e.emit(").fill(0)")  # newSeq(n) -> n zeros
    else:
      e.emit("[]")
    while n.kind != ParRi: skip n
  elif name == "newString":
    skip n; e.emit("\"\"")                    # newString(n) -> empty string
    while n.kind != ParRi: skip n
  elif name == "$":
    skip n; e.emit("String("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "inc":
    skip n; e.emit("("); emitExpr(e, n)
    if n.kind != ParRi: (e.emit(" += "); emitExpr(e, n)) else: e.emit(" += 1")
    e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "&":
    skip n; e.emit("("); emitExpr(e, n); e.emit(" + "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "chr":
    skip n; e.emit("String.fromCharCode("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "ord":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").charCodeAt(0)")
    while n.kind != ParRi: skip n
  elif name == "abs":
    skip n; e.emit("Math.abs("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "min" or name == "max" or name == "sqrt" or name == "floor" or
       name == "ceil" or name == "round" or name == "trunc" or name == "sin" or
       name == "cos" or name == "tan" or name == "exp" or name == "ln" or name == "pow":
    let jn = if name == "ln": "log" else: name    # math.* -> Math.*
    skip n; e.emit("Math." & jn & "(")
    var mfirst = true
    while n.kind != ParRi:
      if not mfirst: e.emit(", ")
      mfirst = false
      emitExpr(e, n)
    e.emit(")")
  elif name == "toLowerAscii" or name == "toLower":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").toLowerCase()")
    while n.kind != ParRi: skip n
  elif name == "toUpperAscii" or name == "toUpper":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").toUpperCase()")
    while n.kind != ParRi: skip n
  elif name == "strip":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").trim()")
    while n.kind != ParRi: skip n
  elif name == "repeat":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").repeat("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "split":
    skip n; e.emit("("); emitExpr(e, n); e.emit(").split("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "contains" or name == "startsWith" or name == "endsWith":
    let jn = if name == "contains": "includes" else: name
    skip n; e.emit("("); emitExpr(e, n); e.emit(")." & jn & "("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  else:
    let boxed = boxLookup(name)                # ",i,j," of boxed param positions
    e.emit(mangle(callee)); inc n
    e.emit("(")
    var first = true
    var idx = 0
    while n.kind != ParRi:
      if not first: e.emit(", ")
      first = false
      if boxed.len > 0 and boxed.contains("," & $idx & ","):
        emitBoxArg(e, n)                       # pass the caller's lval by reference
      else:
        emitExpr(e, n)
      inc idx
    e.emit(")")
  consumeParRi n

proc emitRanges(e: var JsEmitter; rc: var Cursor) =
  ## (ranges V0 V1 (range lo hi) …) -> a JS `||`-chain of `_s === v` / range tests.
  ## The emitjs-specific value rendering; the branch structure is shared (hlwalk).
  if not (rc.kind == ParLe and rc.tagEnum == RangesTagId): return
  inc rc
  var f2 = true
  while rc.kind != ParRi:
    if not f2: e.emit(" || ")
    f2 = false
    if rc.kind == ParLe and rc.tagEnum == RangeTagId:
      inc rc
      e.emit("(_s >= " & exprToStr(rc) & " && _s <= " & exprToStr(rc) & ")")
      consumeParRi rc
    else:
      e.emit("(_s === " & exprToStr(rc) & ")")
  consumeParRi rc

proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool) =
  ## (case SEL (of (ranges V…) BODY) … (else BODY)). Emitted as an if-chain over
  ## a once-bound selector; as an expression it's wrapped in an IIFE. Selector +
  ## branch structure via the shared hlwalk.decodeCase.
  var sel = default(Cursor)
  let branches = decodeCase(n, sel)
  var selc = sel
  let selStr = exprToStr(selc)
  if asExpr: e.emit("(function(_s){ ")
  else: e.emit("{ const _s = " & selStr & "; ")
  var first = true
  for br in branches:
    if br.isElse:
      e.emit(" else { ")
      var bc = br.body
      if asExpr: (e.emit("return "); emitExpr(e, bc); e.emit("; }"))
      else: (emitStmt(e, bc); e.emit(" }"))
    else:
      e.emit(if first: "if(" else: " else if(")
      first = false
      var rc = br.ranges
      emitRanges(e, rc)
      e.emit("){ ")
      var bc = br.body
      if asExpr: (e.emit("return "); emitExpr(e, bc); e.emit("; }"))
      else: (emitStmt(e, bc); e.emit(" }"))
  if asExpr: e.emit(" })(" & selStr & ")")
  else: e.emit(" }")

proc emitExpr(e: var JsEmitter; n: var Cursor; wantBig = false) =
  let bigSfx = if wantBig: "n" else: ""
  case n.kind
  of IntLit:  e.emit($pool.integers[n.intId] & bigSfx); inc n
  of UIntLit: e.emit($pool.uintegers[n.uintId] & bigSfx); inc n
  of FloatLit: e.emit($pool.floats[n.floatId]); inc n
  of CharLit: e.emit(jsString($n.charLit)); inc n
  of StringLit: e.emit(jsString(pool.strings[n.litId])); inc n
  of Symbol, SymbolDef, Ident:
    let nm = mangle(pool.syms[n.symId])
    let eo = enumLookup(nm)
    if eo.len > 0: e.emit(eo)                  # enum value -> its ordinal
    else: e.emit(nm)
    inc n
  of ParLe:
    let t = n.tagEnum
    let bop = binOp(t)
    if bop.len > 0: emitBinop(e, n, bop, t)
    elif t == DivTagId:
      inc n
      let isFloat = n.kind == ParLe and n.tagEnum == FTagId
      let k = if faithfulMode and not isFloat: int64Kind(n) else: 0
      skip n
      if isFloat: (e.emit("("); emitExpr(e, n); e.emit(" / "); emitExpr(e, n); e.emit(")"))
      elif k > 0: (e.emit("_idiv("); emitExpr(e, n, true); e.emit(", "); emitExpr(e, n, true); e.emit(")"))
      else: (e.emit("(Math.trunc("); emitExpr(e, n); e.emit(" / "); emitExpr(e, n); e.emit("))"))
      consumeParRi n
    elif t == ModTagId:
      inc n
      let k = if faithfulMode: int64Kind(n) else: 0
      skip n
      if k > 0: (e.emit("_imod("); emitExpr(e, n, true); e.emit(", "); emitExpr(e, n, true); e.emit(")"))
      else: (e.emit("("); emitExpr(e, n); e.emit(" % "); emitExpr(e, n); e.emit(")"))
      consumeParRi n
    elif t == AndTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" && "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == OrTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" || "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == NotTagId:
      inc n; e.emit("(!"); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == BitnotTagId:
      inc n
      if faithfulMode and n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId):
        let k = int64Kind(n); skip n
        if k > 0:
          let w = if k == 1: "_i64" else: "_u64"
          e.emit(w & "(~"); emitExpr(e, n, true); e.emit(")")
        else: (e.emit("(~"); emitExpr(e, n); e.emit(")"))
      else:
        e.emit("(~"); emitExpr(e, n); e.emit(")")
      consumeParRi n
    elif t == NegTagId:
      inc n
      let k = if faithfulMode: int64Kind(n) else: 0
      skip n
      if k > 0:
        let w = if k == 1: "_i64" else: "_u64"
        e.emit(w & "(-"); emitExpr(e, n, true); e.emit(")")
      else: (e.emit("(-"); emitExpr(e, n); e.emit(")"))
      consumeParRi n
    elif t == HderefTagId or t == HaddrTagId:
      inc n
      if (n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident) and
         boxContains(mangle(pool.syms[n.symId])):
        e.emit(mangle(pool.syms[n.symId]) & ".v"); inc n   # boxed var-param cell
      else:
        emitExpr(e, n, wantBig)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ConvTagId or t == HconvTagId:
      inc n                                     # (conv TYPE VALUE) -> VALUE
      let targetK = if faithfulMode: int64Kind(n) else: 0
      let toInt = n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId)
      skip n                                    # target type; n now at source expr
      if targetK > 0:
        # narrower/number/float source -> bigint: BigInt() then width-wrap.
        let w = if targetK == 1: "_i64" else: "_u64"
        if n.kind == CharLit: (e.emit(w & "(BigInt(" & $int(n.charLit) & "))"); inc n)
        elif looksFloat(n): (e.emit(w & "(BigInt(Math.trunc("); emitExpr(e, n); e.emit(")))"))
        else: (e.emit(w & "(BigInt("); emitExpr(e, n); e.emit("))"))
      elif faithfulMode and producesBig(n):
        # 64-bit (bigint) source -> narrower int / number / float target.
        e.emit("Number("); emitExpr(e, n, true); e.emit(")")
      else:
        if toInt and n.kind == CharLit: (e.emit($int(n.charLit)); inc n)   # ord('A') -> 65
        else: emitExpr(e, n)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == IfTagId:                          # if-EXPRESSION -> IIFE
      inc n
      e.emit("(function(){ ")
      var ifirst = true
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == ElifTagId:
          inc n
          e.emit(if ifirst: "if(" else: " else if(")
          ifirst = false
          emitExpr(e, n); e.emit("){ return "); emitExpr(e, n); e.emit("; }")
          consumeParRi n
        elif n.kind == ParLe and n.tagEnum == ElseTagId:
          inc n; e.emit(" else { return "); emitExpr(e, n); e.emit("; }"); consumeParRi n
        else: skip n
      e.emit(" })()"); consumeParRi n
    elif t == SetconstrTagId:                   # set literal -> JS Set
      inc n; skip n                             # (set TYPE)
      e.emit("(function(){ const _s = new Set(); ")
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == RangeTagId:
          inc n
          let isChar = n.kind == CharLit                # char range -> enumerate by code
          let lo = exprToStr(n); let hi = exprToStr(n)
          if isChar:
            e.emit("for(let _i=(" & lo & ").charCodeAt(0); _i<=(" & hi &
                   ").charCodeAt(0); _i++) _s.add(String.fromCharCode(_i)); ")
          else:
            e.emit("for(let _i=" & lo & "; _i<=" & hi & "; _i++) _s.add(_i); ")
          consumeParRi n
        else:
          e.emit("_s.add(" & exprToStr(n) & "); ")
      e.emit("return _s; })()"); consumeParRi n
    elif t == InsetTagId:                        # membership: (inset TYPE SET VALUE)
      inc n; skip n                             # set type
      # SET (inline setconstr -> OR-chain) then VALUE
      if n.kind == ParLe and n.tagEnum == SetconstrTagId:
        inc n; skip n
        var conds: seq[string] = @[]
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == RangeTagId:
            inc n
            conds.add("(_v >= " & exprToStr(n) & " && _v <= " & exprToStr(n) & ")")
            consumeParRi n
          else:
            conds.add("(_v === " & exprToStr(n) & ")")
        consumeParRi n
        let body = if conds.len > 0: joinList(conds, " || ") else: "false"
        e.emit("(function(_v){ return " & body & "; })(" & exprToStr(n) & ")")
      else:
        let setExpr = exprToStr(n)
        e.emit("(" & setExpr & ".has(" & exprToStr(n) & "))")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == SufTagId:
      inc n                                     # (suf LIT "suffix") -> LIT
      var big = wantBig
      if faithfulMode:
        var probe = n; skip probe
        if probe.kind == StringLit:
          let sfx = pool.strings[probe.litId]
          if sfx == "i64" or sfx == "u64": big = true
      emitExpr(e, n, big)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AconstrTagId:
      inc n; skip n                             # (aconstr TYPE e0 e1 …) -> [e0,e1,…]
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        emitExpr(e, n)
      e.emit("]"); consumeParRi n
    elif t == PrefixTagId:
      inc n                                     # (prefix OP X) — @seq / $tostring
      let opsym = if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: ""
      let op = opName(opsym)
      inc n
      if op == "$": (e.emit("String("); emitExpr(e, n); e.emit(")"))
      else: emitExpr(e, n)                      # `@` on an array literal -> the array
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AtTagId or t == ArratTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitIdx(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ExprTagId:
      inc n; emitExpr(e, n, wantBig)            # (expr VALUE) -> VALUE
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == OconstrTagId:
      inc n; skip n                             # (oconstr TYPE (kv f v) …) -> {f:v,…}
      e.emit("({")
      var first = true
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == KvTagId:
          if not first: e.emit(", ")
          first = false
          inc n
          e.emit(mangle(pool.syms[n.symId]) & ": "); inc n
          emitExpr(e, n)
          while n.kind != ParRi: skip n
          consumeParRi n
        else: skip n
      e.emit("})"); consumeParRi n
    elif t == DotTagId:
      inc n; emitExpr(e, n)                     # (dot OBJ FIELD idx "name")
      e.emit("." & mangle(pool.syms[n.symId])); inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == TupconstrTagId:
      inc n; skip n                             # (tupconstr TYPE v… | (kv f v)…) -> [v…]
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        if n.kind == ParLe and n.tagEnum == KvTagId:
          inc n; skip n; emitExpr(e, n)
          while n.kind != ParRi: skip n
          consumeParRi n
        else: emitExpr(e, n)
      e.emit("]"); consumeParRi n
    elif t == TupatTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitExpr(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CaseTagId:
      emitCase(e, n, true)
    elif t == TrueTagId: (e.emit("true"); skip n)
    elif t == FalseTagId: (e.emit("false"); skip n)
    elif t == NilTagId: (e.emit("null"); skip n)
    elif isCallTag(t):
      emitCall(e, n)
    else:
      skip n; e.emit("undefined")   # TODO: sets/generics/var-params from aifjs-js
  else:
    inc n; e.emit("undefined")

proc collectParams(e: var JsEmitter; n: var Cursor): seq[string] =
  ## (params (param :x . . TYPE .) …) -> the mangled param names. The grammar
  ## navigation is the shared HL-IR skeleton (hlwalk.decodeParams); here we only
  ## mangle to JS names and mark var/out params for boxing.
  result = @[]
  inc n
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ParamTagId:
      inc n
      let pnm = mangle(pool.syms[n.symId]); inc n
      skip n                       # export
      skip n                       # pragmas
      var byRef = false
      if n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId):
        byRef = true               # var/out param -> boxed
      if faithfulMode and not byRef and int64Kind(n) > 0: bigAdd pnm
      skip n                       # type
      while n.kind != ParRi: skip n
      consumeParRi n
      result.add pnm
      if byRef: curBoxed.add pnm
    else:
      skip n
  consumeParRi n

proc emitProc(e: var JsEmitter; n: var Cursor) =
  ## (proc :name … (params …) RETTYPE … (stmts BODY)). Shape via hlwalk.decodeProc;
  ## params come before the body in the grammar, so collect (filling curBoxed)
  ## then emit — a forward decl (no stmts) emits nothing, as before.
  let sh = decodeProc(n)
  let name = mangle(pool.syms[sh.name])
  var params: seq[string] = @[]
  let savedBoxed = curBoxed
  curBoxed = @[]
  if sh.hasParams:
    var pc = sh.params
    params = collectParams(e, pc)              # also fills curBoxed
  # faithful: does this routine return a 64-bit int? (ret type follows params)
  let savedRetBig = curRetBig
  curRetBig = false
  if faithfulMode and sh.hasParams:
    var rc = sh.params
    skip rc                                    # past (params …)
    if rc.kind != ParRi and not (rc.kind == ParLe and rc.tagEnum == StmtsTagId):
      if int64Kind(rc) > 0: curRetBig = true
  if sh.hasBody:
    e.emit("function " & name & "(" & joinList(params, ", ") & "){\n")
    var bc = sh.body
    emitStmts(e, bc)
    e.emit("\n}\n")
  curRetBig = savedRetBig
  curBoxed = savedBoxed

proc emitLocal(e: var JsEmitter; n: var Cursor) =
  ## (var/let/const/result NAME EXPORT PRAGMAS TYPE VALUE) — fixed positional
  ## shape (like interp's execLocal): after the name come export, pragmas, type,
  ## then the initializer (a `.` dot if none).
  let sh = decodeLocal(n)
  let nm = mangle(pool.syms[sh.name])
  let big = faithfulMode and int64Kind(sh.typ) > 0
  if big: bigAdd nm
  e.emit("let " & nm)
  if sh.hasInit:
    var ic = sh.init
    e.emit(" = "); emitExpr(e, ic, big)
  else:
    e.emit(if big: " = 0n" else: " = 0")   # uninitialised — JS-safe default
  e.emit(";")

proc emitAsgn(e: var JsEmitter; n: var Cursor) =
  inc n
  # if the lvalue is a known bigint local, a bare-literal RHS must be bigint too.
  var lhsBig = false
  if faithfulMode and (n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident):
    lhsBig = bigContains(mangle(pool.syms[n.symId]))
  emitExpr(e, n); e.emit(" = "); emitExpr(e, n, lhsBig); e.emit(";")
  consumeParRi n

proc emitIf(e: var JsEmitter; n: var Cursor) =
  var first = true
  for br in decodeIf(n):
    if br.isElse:
      var bc = br.body
      e.emit(" else {\n"); emitStmt(e, bc); e.emit("\n}")
    else:
      var cc = br.cond
      e.emit(if first: "if(" else: " else if(")
      emitExpr(e, cc); e.emit("){\n")
      var bc = br.body
      emitStmt(e, bc); e.emit("\n}")
      first = false

proc emitWhile(e: var JsEmitter; n: var Cursor) =
  inc n
  e.emit("while("); emitExpr(e, n); e.emit("){\n"); emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitRet(e: var JsEmitter; n: var Cursor) =
  inc n
  if n.kind == ParRi: e.emit("return;")
  else:
    e.emit("return "); emitExpr(e, n, curRetBig); e.emit(";")
  consumeParRi n

proc exprToStr(n: var Cursor; wantBig = false): string =
  ## emit one expression into a fresh buffer (for building loop headers).
  var tmp = JsEmitter(js: "")
  emitExpr(tmp, n, wantBig)
  result = tmp.js

proc collExpr(n: var Cursor): string =
  ## dig a for-iterable down to its collection: nimony lowers `for x in xs` to
  ## `items(toOpenArray(xs))` wrapped in hderef; unwrap to `xs`.
  if n.kind == ParLe:
    let t = n.tagEnum
    if t == HderefTagId or t == HaddrTagId:
      inc n
      result = collExpr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
      return
    if t == CallTagId or t == HcallTagId:
      inc n
      let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
      let name = opName(callee)
      if name == "items" or name == "mitems" or name == "pairs" or name == "toOpenArray":
        inc n
        result = collExpr(n)
        while n.kind != ParRi: skip n
        consumeParRi n
        return
  result = exprToStr(n)

proc emitFor(e: var JsEmitter; n: var Cursor) =
  ## (for ITER (unpackflat (let :v …)…) BODY) — range | countdown | collection,
  ## with 1 loop var (`for x in`) or 2 (`for i, x in`).
  inc n
  var kind = 0                  # 0=collection, 1=range, 2=countdown
  var a = "0"                   # range lo / countdown from
  var b = "0"                   # range hi / countdown to
  var cmp = " < "
  var step = "1"
  var coll = ""
  if n.kind == ParLe and n.tagEnum == InfixTagId:
    inc n
    let op = opName(if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: "")
    inc n
    a = exprToStr(n); b = exprToStr(n); consumeParRi n
    if op == "..<": (cmp = " < "; kind = 1)
    elif op == "..": (cmp = " <= "; kind = 1)
    else: coll = "[]"
  else:
    var isCd = false
    if n.kind == ParLe and (n.tagEnum == CallTagId or n.tagEnum == HcallTagId):
      var probe = n; inc probe
      let cn = opName(if probe.kind == Symbol or probe.kind == SymbolDef: pool.syms[probe.symId] else: "")
      if cn == "countdown": isCd = true
    if isCd:
      inc n; skip n             # past call, callee
      a = exprToStr(n); b = exprToStr(n)
      if n.kind != ParRi: step = exprToStr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
      kind = 2
    else:
      coll = collExpr(n)
  # loop variables (1 or 2), from (unpackflat (let :v …)…)
  var vars: seq[string] = @[]
  var loopBig = false                 # counter is a 64-bit int -> bigint (faithful)
  if n.kind == ParLe and n.tagEnum == UnpackflatTagId:
    inc n
    var firstVar = true
    while n.kind != ParRi:
      if n.kind == ParLe and (n.tagEnum == LetTagId or n.tagEnum == VarTagId):
        inc n
        let vnm = mangle(pool.syms[n.symId])
        vars.add vnm; inc n
        skip n                         # export
        skip n                         # pragmas
        if firstVar and faithfulMode and int64Kind(n) > 0:
          loopBig = true
          bigAdd vnm
        firstVar = false
        while n.kind != ParRi: skip n  # type, value
        consumeParRi n
      else: skip n
    consumeParRi n
  else:
    skip n
  let v0 = if vars.len > 0: vars[0] else: "v__i"
  # counter loops over bigint bounds: wrap the endpoints so `i`, the comparison and
  # `i++` / `i -= step` all stay bigint (BigInt() is a no-op on an existing bigint).
  let la = if loopBig: "BigInt(" & a & ")" else: a
  let lb = if loopBig: "BigInt(" & b & ")" else: b
  let lstep = if loopBig: "BigInt(" & step & ")" else: step
  if kind == 1:
    e.emit("for(let " & v0 & " = " & la & "; " & v0 & cmp & lb & "; " & v0 & "++){\n")
    emitStmt(e, n); e.emit("\n}")
  elif kind == 2:
    e.emit("for(let " & v0 & " = " & la & "; " & v0 & " >= " & lb & "; " & v0 & " -= " & lstep & "){\n")
    emitStmt(e, n); e.emit("\n}")
  elif vars.len >= 2:           # for i, x in coll -> indexed
    e.emit("{ const _c = " & coll & "; for(let " & vars[0] & " = 0; " & vars[0] &
           " < _c.length; " & vars[0] & "++){ const " & vars[1] & " = _c[" & vars[0] & "];\n")
    emitStmt(e, n); e.emit("\n} }")
  else:
    e.emit("for(const " & v0 & " of " & coll & "){\n")
    emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitStmt(e: var JsEmitter; n: var Cursor) =
  if n.kind != ParLe:
    inc n
    return
  let t = n.tagEnum
  if t == StmtsTagId: emitStmts(e, n)
  elif t == VarTagId or t == LetTagId or t == ConstTagId or t == GvarTagId or
       t == GletTagId or t == ResultTagId: emitLocal(e, n)
  elif t == AsgnTagId: emitAsgn(e, n)
  elif t == IfTagId: emitIf(e, n)
  elif t == WhileTagId: emitWhile(e, n)
  elif t == RetTagId: emitRet(e, n)
  elif t == CaseTagId: emitCase(e, n, false)
  elif t == ForTagId: emitFor(e, n)
  elif t == BreakTagId: (e.emit("break;"); skip n)
  elif t == ContinueTagId: (e.emit("continue;"); skip n)
  elif isCallTag(t): (emitCall(e, n); e.emit(";"))
  elif t == ProcTagId or t == FuncTagId: emitProc(e, n)
  else: skip n

proc scanEnums(n: var Cursor) =
  ## walk the tree; for (enum … (efld :val … (tup ORD "name"))) record val->ORD.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == EnumTagId:
    inc n
    while n.kind != ParRi:
      if n.kind == ParLe and n.tagEnum == EfldTagId:
        inc n
        let valName = mangle(pool.syms[n.symId]); inc n
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == TupTagId:
            inc n
            if n.kind == IntLit: (enumKeys.add valName; enumVals.add $pool.integers[n.intId])
            while n.kind != ParRi: skip n
            consumeParRi n
          else: skip n
        consumeParRi n
      else: skip n
    consumeParRi n
  else:
    inc n
    while n.kind != ParRi: scanEnums(n)
    consumeParRi n

proc scanProcBoxed(n: var Cursor) =
  ## walk the tree; for each (proc/func :name … (params …)) record which param
  ## positions are var/out, so call sites know which args to box.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == ProcTagId or n.tagEnum == FuncTagId:
    inc n
    let pname = opName(pool.syms[n.symId]); inc n
    var idxs: seq[int] = @[]
    while n.kind != ParRi:
      if n.kind == ParLe and n.tagEnum == ParamsTagId:
        inc n
        var i = 0
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == ParamTagId:
            inc n
            skip n            # param symbol
            skip n; skip n    # export, pragmas
            if n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId):
              idxs.add i
            while n.kind != ParRi: skip n
            consumeParRi n
            inc i
          else: skip n
        consumeParRi n
      else: skip n
    if idxs.len > 0:
      var s = ","
      for bi in idxs: s.add $bi & ","
      boxProcNames.add pname
      boxProcIdx.add s
    consumeParRi n
  else:
    inc n
    while n.kind != ParRi: scanProcBoxed(n)
    consumeParRi n

proc emitModule*(root: var Cursor): string =
  var scanCur = root
  scanEnums(scanCur)            # collect enum ordinals from a separate cursor
  var scanCur2 = root
  scanProcBoxed(scanCur2)       # collect var/out param positions per routine
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  e.emit("function __wf(x){ __out += (Number.isInteger(x) ? x + '.0' : String(x)); }\n")
  e.emit("function __append(c, x){ if(typeof c === 'string') return c + x; c.push(x); return c; }\n")
  if faithfulMode:
    # faithful-export runtime: 64-bit ints are JS `bigint`; wrap arithmetic to the
    # exact two's-complement width and guard integer division. (echo prints a bigint
    # via String(x), i.e. "5" not "5n", so no writer change is needed.)
    e.emit("const _i64 = (x) => BigInt.asIntN(64, x);\n")
    e.emit("const _u64 = (x) => BigInt.asUintN(64, x);\n")
    e.emit("const _idiv = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a / b; };\n")
    e.emit("const _imod = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a % b; };\n")
  # root is the module `(stmts …)`: procs float up (JS hoists function decls),
  # top-level runs at module scope, then we return the captured output.
  emitStmt(e, root)
  e.emit("\nreturn __out;\n")
  result = e.js
