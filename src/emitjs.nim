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

## Exception support. A ref-object type that transitively inherits `Exception`
## is emitted as a real JS `class … extends …` (so `new T(…)` and `x instanceof T`
## work); regular ref-objects stay plain object literals. `excClassNames` holds the
## mangled *Obj*-type names (the ones referenced by `newobj`/`instanceof`);
## `excClassBase` the parallel JS parent (another exc class, or `Error`). Filled by
## scanExcTypes before emission.
var excClassNames: seq[string] = @[]
var excClassBase: seq[string] = @[]
proc isExcClass(nm: string): bool =
  for c in excClassNames:
    if c == nm: return true
  return false
proc excParent(nm: string): string =
  for i in 0 ..< excClassNames.len:
    if excClassNames[i] == nm: return excClassBase[i]
  return "Error"

## `pendingThrow` stashes the JS expression built when nimony assigns a freshly
## constructed exception to its `exc` threadvar; the following `(raise …)` consumes
## it as `throw <expr>`. `curCatchVar` names the active `catch` binding, so a
## `(raise .)` re-raise becomes `throw <catchVar>`.
var pendingThrow = ""
var curCatchVar = ""

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

## nimony `char` and `string`/`cstring` both map to a JS `string`, so the emitter
## can't tell them apart from the type node alone in every context. We track which
## locals/params are `char` vs `string` so a `char -> int` conversion emits
## `.charCodeAt(0)` (a JS one-char string has no numeric value) instead of a bogus
## `Number("A")`/`BigInt("A")`.
var charVars: seq[string] = @[]
var strVars: seq[string] = @[]
proc listHas(xs: seq[string]; nm: string): bool =
  for x in xs:
    if x == nm: return true
  return false
proc charAdd(nm: string) =
  if not listHas(charVars, nm): charVars.add nm
proc strAdd(nm: string) =
  if not listHas(strVars, nm): strVars.add nm

## names (mangled) of locals/params whose static type is a float. A JS `number`
## carries no int-vs-float tag at runtime, so `echo`/`$` of a bare float variable
## would print `1` instead of `1.0` and `int(floatVar)` in faithful mode would hit
## `BigInt(3.9)` (RangeError). `looksFloat` consults this so those route correctly.
var floatVars: seq[string] = @[]
proc floatAdd(nm: string) =
  if not listHas(floatVars, nm): floatVars.add nm

## names (mangled) of locals/params whose static type is a std/sets `HashSet`/
## `OrderedSet`. These map to a native JS `Set`, so `len(s)` must emit `.size`
## (not the seq/array `.length`) and a `contains`/`in` test must emit `.has`.
## Filled by emitLocal/collectParams when the declared type is a set instance.
var setVars: seq[string] = @[]
proc setAdd(nm: string) =
  if not listHas(setVars, nm): setVars.add nm
## tuple locals -> the float element indices (base62-free, small): `t[2]` on a
## `(1, "two", 3.0)` must show `3.0`. Parallel seqs keyed by tuple var name.
var tupleVars: seq[string] = @[]
var tupleFloatIdx: seq[seq[int]] = @[]
proc tupleFloatsFor(nm: string): seq[int] =
  for i in 0 ..< tupleVars.len:
    if tupleVars[i] == nm: return tupleFloatIdx[i]
  return @[]
proc hasInt(xs: seq[int]; v: int): bool =
  for x in xs:
    if x == v: return true
  return false

## true iff the proc currently being emitted returns a 64-bit int (faithful mode);
## a bare-literal `return` in such a proc must emit bigint.
var curRetBig: bool = false

## names (mangled) of the current proc's plain (non-boxed) bigint value params
## (faithful mode). Coerced to bigint at function entry so an untyped literal
## argument (`bump(5)` — nimony passes a bare `5`, not `5n`) can't leak a `number`
## into the body's bigint arithmetic and trigger a JS mix-BigInt-and-number error.
var curBigParams: seq[string] = @[]

## JS/TS reserved words that can't stand as a bare identifier — a pretty name that
## lands on one is prefixed with `_`.
var jsReserved: seq[string] = @["if","for","class","return","function","var","let",
  "const","new","delete","typeof","instanceof","in","of","do","while","switch",
  "case","default","break","continue","this","super","null","true","false","void",
  "yield","await","async","static","import","export","extends","enum","try","catch",
  "finally","throw","with","debugger"]
proc isReservedJs(s: string): bool =
  for r in jsReserved:
    if r == s: return true
  return false

## GLOBAL rename table: original full nimony symbol (`fib.1.main`) -> a readable,
## valid JS identifier (`fib`). Parallel seqs (nimony's `Table.[]=` is `.raises`).
## `renameTaken` is the set of pretty names already handed out — pre-seeded with the
## emitter's own runtime helpers / IIFE+loop temporaries so no USER symbol can ever
## shadow them. First sight of a symbol claims its base name; a base already taken by
## a DIFFERENT symbol gets `_2`, `_3`, … until unique (guaranteed collision-free;
## over-disambiguates same-named locals in distinct scopes — acceptable for v1).
var renameKeys: seq[string] = @[]
var renameVals: seq[string] = @[]
var renameTaken: seq[string] = @["__out","__w","__wf","__sf","__append",
  "_i64","_u64","_idiv","_imod","_s","_v","_c","_i","_a","_b","_r","_x","_ex","v__i"]
proc prettyTaken(p: string): bool =
  for a in renameTaken:
    if a == p: return true
  return false

## the readable base of a nimony symbol: the segment before the first `.`, sanitized
## to a valid JS identifier and guarded against reserved words / bad starts / empty.
proc prettyBase(name: string): string =
  var res = ""
  var i = 0
  while i < name.len and name[i] != '.':
    let ch = name[i]
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: res.add ch
    else: res.add '_'
    inc i
  if res.len == 0: res = "_"
  elif res[0] in {'0'..'9'}: res = "_" & res
  if isReservedJs(res): res = "_" & res
  return res

## a nimony symbol -> a stable, readable, valid JS identifier (see renameTaken).
proc mangle(name: string): string =
  for i in 0 ..< renameKeys.len:
    if renameKeys[i] == name: return renameVals[i]
  let base = prettyBase(name)
  var cand = base
  var k = 2
  while prettyTaken(cand):
    cand = base & "_" & $k
    inc k
  renameKeys.add name
  renameVals.add cand
  renameTaken.add cand
  return cand

## bare callee/operator name — everything before the first `.<digit>`.
proc opName(name: string): string =
  var i = 0
  while i + 1 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}: return name[0 ..< i]
    inc i
  result = name.strip(leading = false, chars = {'.'})

## true iff `name` carries a generic-instance segment (`.<digits>.I<hash>` — e.g.
## `add.0.I8fahwb`). Instance hashes start with a capital `I`; user-module hashes
## are lowercase (`proxr24ld1`), so a leading capital `I` after the disambiguation
## number reliably marks a monomorphized system/generic instance.
proc isInstanceSym(name: string): bool =
  var i = 0
  while i + 2 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}:
      var j = i + 1
      while j < name.len and name[j] in {'0'..'9'}: inc j
      if j + 1 < name.len and name[j] == '.' and name[j+1] == 'I': return true
      i = j
    else:
      inc i
  return false

## true iff the callee is a *real* builtin/magic — a system-module symbol
## (`.sysvq0asl`) or a generic instance — rather than a user proc that merely
## shares a base name (`add`/`len`/`newSeq`/`$`/…). Gates every name-keyed magic
## branch so a user `proc add`/`len`/… is emitted as a plain call, not hijacked.
proc isMagicSym(name: string): bool =
  result = name.contains("sysvq0asl") or isInstanceSym(name)

## the mangled Obj-class name behind a `(ref X (notnil))` | `X` type node (the
## form `newobj`/`instanceof` reference); "" if it is not a plain symbol/ref.
proc excRefClassName(c: Cursor): string =
  var n = c
  if n.kind == ParLe and n.tagEnum == RefTagId: inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    result = mangle(pool.syms[n.symId])
  else:
    result = ""

## true iff the cursor is nimony's `exc` exception threadvar (a system global).
proc isExcThreadvar(c: Cursor): bool =
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    let nm = pool.syms[c.symId]
    return opName(nm) == "exc" and nm.contains("sysvq0asl")
  return false

## classify a type node (unwrapping mut/out/sink/lent/rangetype) as char / string.
## 1 = char, 2 = string/cstring, 0 = neither.
proc typeNamed(c: Cursor): int =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  case n.kind
  of Symbol, SymbolDef, Ident:
    let nm = opName(pool.syms[n.symId])
    if nm == "char": return 1
    elif nm == "string" or nm == "cstring": return 2
    else: return 0
  of ParLe:
    let t = n.tagEnum
    if t == CTagId: return 1
    elif t == StringTagId or t == CstringTagId: return 2
    else: return 0
  else: return 0

## true iff a type node denotes a std/sets `HashSet`/`OrderedSet` (unwrapping
## mut/out/sink/lent/rangetype). Such a value maps to a native JS `Set`.
proc isSetType(c: Cursor): bool =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    let nm = opName(pool.syms[n.symId])
    return nm == "HashSet" or nm == "OrderedSet"
  return false

## true iff the expression (unwrapping a leading haddr/hderef) is a known set var
## — the set operand of an `incl`/`excl`/`contains`/`len` magic call.
proc operandIsSet(c: Cursor): bool =
  var n = c
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    return listHas(setVars, mangle(pool.syms[n.symId]))
  return false

## at a `(call CALLEE ARG0 …)` with `n` positioned on the callee symbol, is the
## first argument a set var? (peeks a copy; does not advance `n`).
proc callFirstArgIsSet(c: Cursor): bool =
  var p = c; inc p                     # past the callee -> first arg
  operandIsSet(p)

## true iff the conversion source `n` yields a JS `string` that models a nimony
## `char` — a char var/param, a `CharLit`, an index into a `string`, or a nested
## char-producing conv. Such a source needs `.charCodeAt(0)` to become an int.
proc sourceIsChar(n: Cursor): bool =
  case n.kind
  of CharLit: return true
  of Symbol, SymbolDef, Ident: return listHas(charVars, mangle(pool.syms[n.symId]))
  of ParLe:
    let t = n.tagEnum
    if t == AtTagId or t == ArratTagId:
      var d = n; inc d
      if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
        return listHas(strVars, mangle(pool.syms[d.symId]))
      return false
    elif t == CallTagId or t == HcallTagId or t == CmdTagId:
      var d = n; inc d                        # callee
      if (d.kind == Symbol or d.kind == SymbolDef) and opName(pool.syms[d.symId]) == "[]":
        inc d                                 # container arg
        if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
          return listHas(strVars, mangle(pool.syms[d.symId]))
      return false
    elif t == ConvTagId or t == HconvTagId:
      var d = n; inc d
      return d.kind == ParLe and d.tagEnum == CTagId
    else: return false
  else: return false

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
proc emitArrow(e: var JsEmitter; n: var Cursor)
proc collExpr(n: var Cursor): string

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
proc isFloatType(c: Cursor): bool =
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId or n.tagEnum == RangetypeTagId):
    inc n
  if n.kind == ParLe and n.tagEnum == FTagId: return true
  if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
    let nm = opName(pool.syms[n.symId])
    return nm == "float" or nm == "float32" or nm == "float64" or
           nm == "cfloat" or nm == "cdouble"
  return false

## the float element indices of a `(tuple T0 T1 …)` type node ((kv f T) for named).
proc tupleFloatIndices(c: Cursor): seq[int] =
  result = @[]
  var n = c
  while n.kind == ParLe and (n.tagEnum == MutTagId or n.tagEnum == OutTagId or
        n.tagEnum == SinkTagId or n.tagEnum == LentTagId):
    inc n
  if not (n.kind == ParLe and n.tagEnum == TupleTagId): return
  inc n
  var idx = 0
  while n.kind != ParRi:
    var el = n
    if el.kind == ParLe and el.tagEnum == KvTagId:
      inc el; skip el                          # (kv field TYPE) -> TYPE
    if isFloatType(el): result.add idx
    skip n
    inc idx

proc looksFloat(c: Cursor): bool =
  if c.kind == FloatLit: return true
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    return listHas(floatVars, mangle(pool.syms[c.symId]))
  if c.kind != ParLe: return false
  let t = c.tagEnum
  if t == TupatTagId:                          # (tupat tupleVar idx) into a float slot
    var d = c; inc d
    if d.kind == Symbol or d.kind == SymbolDef or d.kind == Ident:
      let fs = tupleFloatsFor(mangle(pool.syms[d.symId]))
      if fs.len > 0:
        skip d                                 # past the tuple operand
        if d.kind == IntLit: return hasInt(fs, int(pool.integers[d.intId]))
    return false
  if t == AddTagId or t == SubTagId or t == MulTagId or t == DivTagId:
    var d = c; inc d
    return d.kind == ParLe and d.tagEnum == FTagId
  if t == CallTagId or t == HcallTagId:
    var d = c; inc d
    let callee = if d.kind == Symbol or d.kind == SymbolDef: pool.syms[d.symId] else: ""
    let nm = opName(callee)
    return nm == "sqrt" or nm == "pow" or nm == "sin" or nm == "cos" or nm == "tan" or
           nm == "exp" or nm == "ln" or nm == "hypot" or nm == "floor" or nm == "ceil"
  if t == ConvTagId or t == HconvTagId:      # float(x) / conv-to-float -> show N.0
    var d = c; inc d
    return d.kind == ParLe and d.tagEnum == FTagId
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

proc setOperandStr(n: var Cursor): string =
  ## consume one set operand (a `(haddr s)` from a `var`-param call, or a bare `s`)
  ## and return its JS expression — the receiver of a native `Set` method.
  if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
    inc n
    result = exprToStr(n)
    while n.kind != ParRi: skip n
    consumeParRi n
  else:
    result = exprToStr(n)

proc emitCall(e: var JsEmitter; n: var Cursor) =
  ## (call CALLEE ARGS…) / (cmd …). echo -> write(stdout,X) -> __w(X); the common
  ## seq/string builtins map to native JS; everything else is a plain call.
  inc n
  let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
  let name = opName(callee)
  let magic = isMagicSym(callee)   # gate name-keyed magics: user procs must not be hijacked
  if name == "write":
    skip n; skip n                # callee, stdout
    e.emit(if looksFloat(n): "__wf(" else: "__w(")
    emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "len" and magic:
    # `len` yields a 64-bit int. In faithful mode that is a `bigint`, so wrap the
    # native `.length` (a JS `number`) — otherwise `xs.len - 1` mixes bigint with
    # number (the surrounding int64 arithmetic emits its `1` as `1n`). emitIdx
    # coerces back with Number(), so index uses stay correct. A HashSet maps to a
    # native `Set`, whose element count is `.size` (NOT `.length`).
    let prop = if callFirstArgIsSet(n): ".size)" else: ".length)"
    skip n
    if faithfulMode: e.emit("BigInt(")
    e.emit("("); emitExpr(e, n); e.emit(prop)
    if faithfulMode: e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "initHashSet" and magic:
    skip n; e.emit("new Set()")               # std/sets: fresh empty HashSet
    while n.kind != ParRi: skip n
  elif name == "incl" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)                  # set receiver (drop the (haddr …))
    e.emit("(" & sv & ".add("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "excl" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)
    e.emit("(" & sv & ".delete("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "contains" and magic and callFirstArgIsSet(n):
    skip n                                     # callee
    let sv = setOperandStr(n)                  # `x in s` -> s.has(x)
    e.emit("(" & sv & ".has("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "[]" and magic:
    skip n                                   # callee
    let container = exprToStr(n)             # container (string/seq/array)
    if n.kind == ParLe and n.tagEnum == InfixTagId:
      # slice: (infix `..`/`..<` lo hi) -> JS .slice(lo, hi(+1))
      var ic = n
      inc ic
      let sliceOp = opName(if ic.kind == Symbol or ic.kind == Ident: pool.syms[ic.symId] else: "")
      inc ic
      let lo = exprToStr(ic)
      let hi = exprToStr(ic)
      let lo2 = if faithfulMode: "Number(" & lo & ")" else: lo
      let hi2 = if faithfulMode: "Number(" & hi & ")" else: hi
      # `..` is inclusive (end = hi+1), `..<` is exclusive (end = hi)
      let endStr = if sliceOp == "..<": hi2 else: "(" & hi2 & " + 1)"
      e.emit(container & ".slice(" & lo2 & ", " & endStr & ")")
      skip n                                 # the slice infix arg
    else:
      e.emit("(" & container & "["); emitIdx(e, n); e.emit("])")
    while n.kind != ParRi: skip n
  elif name == "[]=" and magic:
    skip n                                   # callee
    var container = ""                       # (haddr LVAL) | LVAL
    if n.kind == ParLe and (n.tagEnum == HaddrTagId or n.tagEnum == HderefTagId):
      inc n; container = exprToStr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
    else:
      container = exprToStr(n)
    e.emit("(" & container & "["); emitIdx(e, n); e.emit("] = "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "add" and magic:
    skip n
    let lv = exprToStr(n)                    # target: seq push, or string reassign
    e.emit("(" & lv & " = __append(" & lv & ", "); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif (name == "newSeq" or name == "newSeqUninit" or name == "newSeqOfCap" or
       name == "newSeqUninitialized") and magic:
    skip n                                   # seq constructors -> JS array
    if name == "newSeq" and n.kind != ParRi:
      e.emit("new Array("); emitIdx(e, n); e.emit(").fill(0)")  # newSeq(n) -> n zeros
    else:
      e.emit("[]")
    while n.kind != ParRi: skip n
  elif name == "newString" and magic:
    skip n; e.emit("\"\"")                    # newString(n) -> empty string
    while n.kind != ParRi: skip n
  elif name == "$" and magic:
    skip n
    if looksFloat(n): (e.emit("__sf("); emitExpr(e, n); e.emit(")"))
    else: (e.emit("String("); emitExpr(e, n); e.emit(")"))
    while n.kind != ParRi: skip n
  elif (name == "==" or name == "!=" or name == "<" or name == "<=" or
        name == ">" or name == ">=") and magic:
    # operator-overload comparison emitted as a call (e.g. string ==/</>): JS
    # strings compare lexicographically, so map to the native operator.
    let jsOp = (if name == "==": " === " elif name == "!=": " !== " else: " " & name & " ")
    skip n; e.emit("("); emitExpr(e, n); e.emit(jsOp); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "inc" and magic:
    skip n; e.emit("("); emitExpr(e, n)
    if n.kind != ParRi: (e.emit(" += "); emitExpr(e, n)) else: e.emit(" += 1")
    e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "&" and magic:
    skip n; e.emit("("); emitExpr(e, n); e.emit(" + "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "chr" and magic:
    skip n; e.emit("String.fromCharCode("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "ord" and magic:
    skip n; e.emit("("); emitExpr(e, n); e.emit(").charCodeAt(0)")
    while n.kind != ParRi: skip n
  elif (name == "filter" or name == "map") and magic:
    # std/sequtils higher-order funcs -> native JS Array.filter/.map. Shape:
    # (call filter/map INSTANCE (hcall toOpenArray SEQ) CLOSURE). The collection is
    # wrapped in toOpenArray/items — collExpr unwraps it back to the seq; the closure
    # is emitted as a JS arrow (via the (expr (stmts (proc …) ref)) path). Native
    # .filter/.map ignore the extra (index, array) callback args, so fixed-arity
    # arrows are safe.
    skip n                                   # callee
    let coll = collExpr(n)                    # unwrap toOpenArray -> the seq
    e.emit("(" & coll & "." & name & "(")
    emitExpr(e, n)                            # the predicate/transform closure
    e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "abs" and magic:
    skip n; e.emit("Math.abs("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif (name == "min" or name == "max") and magic:
    skip n; e.emit("Math." & name & "(")
    var mfirst = true
    while n.kind != ParRi:
      if not mfirst: e.emit(", ")
      mfirst = false
      emitExpr(e, n)
    e.emit(")")
  elif name == "sqrt" or name == "floor" or
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
  # faithful: a 64-bit-int selector is a bigint but the `of` labels are numbers,
  # so `_s === 0` is always false — coerce the selector to Number for comparison.
  let selStr = if faithfulMode and producesBig(sel): "Number(" & exprToStr(selc) & ")"
               else: exprToStr(selc)
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
      # bitnot always carries a leading type child (i N)/(u N); skip it in both
      # modes (fast mode used to emit it as an expression and desync the cursor).
      var k = 0
      if n.kind == ParLe and (n.tagEnum == ITagId or n.tagEnum == UTagId):
        if faithfulMode: k = int64Kind(n)
        skip n
      if k > 0:
        let w = if k == 1: "_i64" else: "_u64"
        e.emit(w & "(~"); emitExpr(e, n, true); e.emit(")")
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
      let toChar = n.kind == ParLe and n.tagEnum == CTagId
      skip n                                    # target type; n now at source expr
      if targetK > 0:
        # narrower/number/float source -> bigint: BigInt() then width-wrap.
        let w = if targetK == 1: "_i64" else: "_u64"
        if n.kind == CharLit: (e.emit(w & "(BigInt(" & $int(n.charLit) & "))"); inc n)
        elif sourceIsChar(n): (e.emit(w & "(BigInt("); emitExpr(e, n); e.emit(".charCodeAt(0)))"))
        elif looksFloat(n): (e.emit(w & "(BigInt(Math.trunc("); emitExpr(e, n); e.emit(")))"))
        else: (e.emit(w & "(BigInt("); emitExpr(e, n); e.emit("))"))
      elif faithfulMode and producesBig(n):
        # 64-bit (bigint) source -> narrower int / number / float target.
        e.emit("Number("); emitExpr(e, n, true); e.emit(")")
      else:
        if toInt and n.kind == CharLit: (e.emit($int(n.charLit)); inc n)   # ord('A') -> 65
        elif toInt and sourceIsChar(n): (e.emit("("); emitExpr(e, n); e.emit(").charCodeAt(0)"))
        elif toInt: (e.emit("Math.trunc("); emitExpr(e, n); e.emit(")"))
        elif toChar and not sourceIsChar(n): (e.emit("String.fromCharCode("); emitExpr(e, n); e.emit(")"))
        else: emitExpr(e, n)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CastTagId:
      # (cast TYPE VALUE) — a ref/pointer cast is identity in JS; emit VALUE.
      inc n; skip n
      emitExpr(e, n, wantBig)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == InstanceofTagId:
      # (instanceof VALUE TYPE) -> `VALUE instanceof Class` (exception dispatch).
      inc n
      emitExpr(e, n)
      e.emit(" instanceof ")
      let cls = excRefClassName(n)
      e.emit(if cls.len > 0: cls else: "Object")
      skip n
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
    elif t == CardTagId:                          # card(set) -> element count
      inc n; skip n                               # (card TYPE SET) -> SET.size
      if faithfulMode: e.emit("BigInt(")
      e.emit("("); emitExpr(e, n); e.emit(".size)")
      if faithfulMode: e.emit(")")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == PlussetTagId or t == MinussetTagId or t == MulsetTagId or
         t == XorsetTagId:
      # (plusset/minusset/mulset/xorset TYPE A B) — set algebra over JS `Set`s.
      # union: keep A + all of B; difference: A minus B; intersection: A ∩ B;
      # symmetric difference: elements in exactly one. Each builds a fresh Set so
      # the operands are never mutated.
      inc n; skip n                               # set type
      let body =
        if t == PlussetTagId:
          "const _r = new Set(_a); for(const _x of _b) _r.add(_x); return _r;"
        elif t == MinussetTagId:
          "const _r = new Set(_a); for(const _x of _b) _r.delete(_x); return _r;"
        elif t == MulsetTagId:
          "const _r = new Set(); for(const _x of _a) if(_b.has(_x)) _r.add(_x); return _r;"
        else:
          "const _r = new Set(_a); for(const _x of _b){ if(_r.has(_x)) _r.delete(_x); else _r.add(_x); } return _r;"
      e.emit("(function(_a,_b){ " & body & " })(")
      emitExpr(e, n); e.emit(", "); emitExpr(e, n); e.emit(")")
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
      inc n                                     # (aconstr TYPE e0 e1 …) -> [e0,e1,…]
      # faithful: if the element type is a 64-bit int, emit bigint elements so a
      # later `s + xs[i]` (bigint arithmetic) doesn't mix bigint with number.
      var elemBig = false
      if faithfulMode and n.kind == ParLe and n.tagEnum == ArrayTagId:
        var tc = n; inc tc                      # (array ELEMTYPE lengthtype)
        elemBig = int64Kind(tc) > 0
      skip n                                    # type
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        emitExpr(e, n, elemBig)
      e.emit("]"); consumeParRi n
    elif t == PrefixTagId:
      inc n                                     # (prefix OP X) — @seq / $tostring
      let opsym = if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: ""
      let op = opName(opsym)
      inc n
      if op == "$":
        if looksFloat(n): (e.emit("__sf("); emitExpr(e, n); e.emit(")"))
        else: (e.emit("String("); emitExpr(e, n); e.emit(")"))
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
    elif t == StmtsTagId:
      # a stmts block used as an expression. The one case aowljs produces this for
      # is a nested proc value (a closure): `(stmts (proc :anon …) SYMREF)` — a local
      # proc definition followed by a reference to it. Emit the proc as a JS arrow
      # function; lexical capture is free in JS, so the returned arrow closes over the
      # enclosing scope. The trailing self-reference is dropped.
      inc n
      var emitted = false
      while n.kind != ParRi:
        if not emitted and n.kind == ParLe and (n.tagEnum == ProcTagId or n.tagEnum == FuncTagId):
          emitArrow(e, n); emitted = true
        else:
          skip n
      if not emitted: e.emit("undefined")
      consumeParRi n
    elif t == OconstrTagId or t == NewobjTagId:
      # (oconstr TYPE (kv f v) …) — a plain object literal {f:v,…}. A `ref object`
      # sem's as (newobj TYPE (kv f v) …): under JS's GC the ref is just the object
      # reference, so it lowers to the identical literal. Inherited base fields are
      # already flattened into the kv list by sem. Omitted ref fields default to a
      # nil-conv (-> null), so every field carries its zero value.
      inc n
      # An exception type is a real JS class: `new Cls({fields})`. A plain
      # ref/value object stays an object literal `({fields})`.
      let cls = excRefClassName(n)
      let isExc = cls.len > 0 and isExcClass(cls)
      skip n                                     # TYPE
      if isExc: e.emit("new " & cls & "(")
      e.emit("({")
      var first = true
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == KvTagId:
          if not first: e.emit(", ")
          first = false
          inc n
          e.emit(mangle(pool.syms[n.symId]) & ": "); inc n
          emitExpr(e, n)
          while n.kind != ParRi: skip n         # trailing inheritance-depth marker
          consumeParRi n
        else: skip n
      e.emit("})")
      if isExc: e.emit(")")
      consumeParRi n
    elif t == DotTagId or t == DdotTagId:
      # (dot OBJ FIELD idx "name"); ddot is the ref-object deref-dot — the deref is
      # implicit in JS (objects are references), so both are just `OBJ.field`.
      inc n; emitExpr(e, n)
      e.emit("." & mangle(pool.syms[n.symId])); inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == BaseobjTagId:
      # (baseobj TYPE depth VALUE) — an upcast to a base object. In JS an upcast is
      # identity (the same object reference), so emit just VALUE.
      inc n; skip n; skip n                     # TYPE, depth
      emitExpr(e, n)
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
      let typeCur = n
      if faithfulMode and not byRef and int64Kind(n) > 0:
        bigAdd pnm
        curBigParams.add pnm
      case typeNamed(typeCur)
      of 1: charAdd pnm
      of 2: strAdd pnm
      else: discard
      if isSetType(typeCur): setAdd pnm        # HashSet param -> native JS Set
      if isFloatType(typeCur): floatAdd pnm    # float params -> echo/$ show .0
      skip n                       # type
      while n.kind != ParRi: skip n
      consumeParRi n
      result.add pnm
      if byRef: curBoxed.add pnm
    else:
      skip n
  consumeParRi n

proc emitProc(e: var JsEmitter; n: var Cursor; isIter = false) =
  ## (proc :name … (params …) RETTYPE … (stmts BODY)). Shape via hlwalk.decodeProc;
  ## params come before the body in the grammar, so collect (filling curBoxed)
  ## then emit — a forward decl (no stmts) emits nothing, as before.
  ## `isIter` marks an (iterator …) routine, emitted as a JS `function*` generator
  ## (its `(yld v)` bodies become `yield v`); a `for x in it(…)` then `for..of`s it.
  let sh = decodeProc(n)
  let rawName = pool.syms[sh.name]
  # ARC/RTTI hook instances (`=destroy`/`=wasmoved`/`=dup`/`=copy`/`=sinkh`/`=trace`)
  # are compiler-generated memory-management machinery, all named with a leading `=`.
  # JS is garbage-collected, so they're dead weight — drop them (decodeProc already
  # consumed the node). `=destroy` on an inheriting type sems as a `method`, which
  # emitStmt skips already; this catches the plain-proc hooks. User procs never begin
  # with `=`, so nothing user-defined is dropped.
  if rawName.len > 0 and rawName[0] == '=': return
  let name = mangle(rawName)
  var params: seq[string] = @[]
  let savedBoxed = curBoxed
  curBoxed = @[]
  let savedBigParams = curBigParams
  curBigParams = @[]
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
    let kw = if isIter: "function* " else: "function "
    e.emit(kw & name & "(" & joinList(params, ", ") & "){\n")
    # coerce plain bigint params so an untyped-literal argument (a bare `number`)
    # can't mix with bigint arithmetic inside the body. BigInt() is a no-op on an
    # existing bigint, so typed callers are unaffected.
    for bp in curBigParams: e.emit("  " & bp & " = BigInt(" & bp & ");\n")
    var bc = sh.body
    emitStmts(e, bc)
    e.emit("\n}\n")
  curRetBig = savedRetBig
  curBoxed = savedBoxed
  curBigParams = savedBigParams

proc emitArrow(e: var JsEmitter; n: var Cursor) =
  ## Emit an anonymous/nested (proc …) as a JS arrow function value:
  ##   (x) => { <body> }
  ## Used for closures — the arrow captures the enclosing scope lexically, so a
  ## `proc(x): int = x + n` returned from `makeAdder(n)` becomes `(x) => { … }`
  ## that closes over `n`. A `(proctype …)` value needs no JS type annotation.
  let sh = decodeProc(n)
  var params: seq[string] = @[]
  let savedBoxed = curBoxed
  curBoxed = @[]
  let savedBigParams = curBigParams
  curBigParams = @[]
  if sh.hasParams:
    var pc = sh.params
    params = collectParams(e, pc)
  let savedRetBig = curRetBig
  curRetBig = false
  if faithfulMode and sh.hasParams:
    var rc = sh.params
    skip rc
    if rc.kind != ParRi and not (rc.kind == ParLe and rc.tagEnum == StmtsTagId):
      if int64Kind(rc) > 0: curRetBig = true
  e.emit("(" & joinList(params, ", ") & ") => {\n")
  for bp in curBigParams: e.emit("  " & bp & " = BigInt(" & bp & ");\n")
  if sh.hasBody:
    var bc = sh.body
    emitStmts(e, bc)
  e.emit("\n}")
  curRetBig = savedRetBig
  curBoxed = savedBoxed
  curBigParams = savedBigParams

proc emitLocal(e: var JsEmitter; n: var Cursor) =
  ## (var/let/const/result NAME EXPORT PRAGMAS TYPE VALUE) — fixed positional
  ## shape (like interp's execLocal): after the name come export, pragmas, type,
  ## then the initializer (a `.` dot if none).
  let sh = decodeLocal(n)
  let nm = mangle(pool.syms[sh.name])
  let big = faithfulMode and int64Kind(sh.typ) > 0
  if big: bigAdd nm
  let isSet = isSetType(sh.typ)               # HashSet -> native JS Set
  if isSet: setAdd nm
  let tn = typeNamed(sh.typ)                  # distinguish char (charCodeAt) from string
  if tn == 1: charAdd nm
  elif tn == 2:
    var isCh = false
    if sh.hasInit:
      var ic = sh.init
      if ic.kind == CharLit: isCh = true
    if isCh: charAdd nm else: strAdd nm
  block:                                        # track float vars (echo/$ must show .0)
    var isF = isFloatType(sh.typ)
    if not isF and sh.hasInit:
      var ic = sh.init
      if ic.kind == FloatLit: isF = true
    if isF: floatAdd nm
  block:                                        # track a tuple var's float element slots
    let fis = tupleFloatIndices(sh.typ)
    if fis.len > 0:
      tupleVars.add nm
      tupleFloatIdx.add fis
  e.emit("let " & nm)
  if sh.hasInit:
    var ic = sh.init
    e.emit(" = "); emitExpr(e, ic, big)
  elif isSet:
    e.emit(" = new Set()")                 # uninitialised HashSet -> empty JS Set
  else:
    e.emit(if big: " = 0n" else: " = 0")   # uninitialised — JS-safe default
  e.emit(";")

proc emitAsgn(e: var JsEmitter; n: var Cursor) =
  inc n
  if isExcThreadvar(n):
    # nimony threads a raise through the `exc` global: `exc = <newobj>` right
    # before `(raise …)`. Stash the constructed exception so the raise throws it;
    # `exc = nil` / `exc = err` bookkeeping is dropped (JS uses the catch binding).
    skip n                                       # LHS (the exc threadvar)
    if n.kind == ParLe and (n.tagEnum == CastTagId or n.tagEnum == NewobjTagId or
                            n.tagEnum == OconstrTagId):
      var tmp = JsEmitter(js: "")
      var rhs = n
      emitExpr(tmp, rhs)
      pendingThrow = tmp.js
    skip n                                        # RHS
    consumeParRi n
    return
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
      # inspect the callee via a probe so an unmatched call keeps `n` at the `(call`
      # for the exprToStr fallthrough below (a bare iterator call, e.g. `evens(10)`,
      # must be emitted whole as the for..of iterable — not unwrapped).
      var probe = n; inc probe
      let callee = if probe.kind == Symbol or probe.kind == SymbolDef: pool.syms[probe.symId] else: ""
      let name = opName(callee)
      if name == "items" or name == "mitems" or name == "pairs" or name == "toOpenArray":
        inc n; inc n                 # past the `(call` and its callee -> the collection
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
    # faithful: a 64-bit index var is a bigint, but `_c.length` and the JS index
    # slot are `number` — start at 0n, compare against BigInt(length), coerce the
    # element read with Number(i).
    let i0 = if loopBig: "0n" else: "0"
    let len = if loopBig: "BigInt(_c.length)" else: "_c.length"
    let idxRead = if loopBig: "Number(" & vars[0] & ")" else: vars[0]
    e.emit("{ const _c = " & coll & "; for(let " & vars[0] & " = " & i0 & "; " & vars[0] &
           " < " & len & "; " & vars[0] & "++){ const " & vars[1] & " = _c[" & idxRead & "];\n")
    emitStmt(e, n); e.emit("\n} }")
  else:
    e.emit("for(const " & v0 & " of " & coll & "){\n")
    emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitTry(e: var JsEmitter; n: var Cursor) =
  ## (try BODY (except …)… (fin STMTS)?) — the lowering nimony emits for `defer`
  ## (a bare `try … (fin …)`) and for `try/except/finally`. Maps to JS
  ## `try { BODY } catch(_ex){ … } finally { … }`. The `fin` clause runs on every
  ## exit path (including a `return` inside BODY), matching nimony `defer`/finally.
  inc n
  e.emit("try {\n")
  emitStmt(e, n)                       # the protected body (a stmts block)
  e.emit("\n}")
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ExceptTagId:
      # (except . BODY) — nimony has already lowered `except T as e / except:` into
      # an `if (instanceof err T) …` cascade inside BODY, threaded through the `exc`
      # global and an `err` alias. JS has one dynamic catch binding, so: name the
      # catch after that `err` alias (the `(let :err … exc)` is then redundant and
      # dropped), and let the cascade's `instanceof`/`cursor`/re-raise fall out of
      # the generic emit (see emitExpr/InstanceofTagId, CursorTagId, RaiseTagId).
      inc n                                       # past 'except'
      if n.kind == DotToken: inc n                # catch-all filter `.`
      elif n.kind != ParRi: skip n                # explicit type filter (unused in JS)
      var catchVar = "_ex"
      block:                                      # probe BODY for `(let :err … exc)`
        var probe = n
        if probe.kind == ParLe and probe.tagEnum == StmtsTagId:
          inc probe
          while probe.kind != ParRi:
            if probe.kind == ParLe and probe.tagEnum == LetTagId:
              inc probe
              catchVar = mangle(pool.syms[probe.symId])
              break
            else: skip probe
      e.emit(" catch(" & catchVar & ") {\n")
      let savedCatch = curCatchVar
      curCatchVar = catchVar
      if n.kind == ParLe and n.tagEnum == StmtsTagId:
        inc n
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == LetTagId: skip n   # drop `let err = exc`
          else: emitStmt(e, n)
        consumeParRi n
      else:
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == StmtsTagId: emitStmt(e, n)
          else: skip n
      curCatchVar = savedCatch
      e.emit("\n}")
      consumeParRi n
    elif n.kind == ParLe and n.tagEnum == FinTagId:
      inc n
      e.emit(" finally {\n")
      emitStmt(e, n)
      e.emit("\n}")
      while n.kind != ParRi: skip n
      consumeParRi n
    else:
      skip n
  consumeParRi n

proc emitType(e: var JsEmitter; n: var Cursor) =
  ## Most type decls vanish (JS is untyped). An exception type, though, must be a
  ## real class so `new T(…)` / `x instanceof T` work — emit it as one. Base fields
  ## are flattened into every `newobj`, so the constructor just copies the field bag.
  var c = n
  inc c
  if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
    let nm = mangle(pool.syms[c.symId])
    if isExcClass(nm):
      e.emit("class " & nm & " extends " & excParent(nm) &
             " { constructor(f){ super(); if(f) Object.assign(this, f); } }\n")
  skip n

proc emitStmt(e: var JsEmitter; n: var Cursor) =
  if n.kind != ParLe:
    inc n
    return
  let t = n.tagEnum
  if t == StmtsTagId: emitStmts(e, n)
  elif t == TryTagId: emitTry(e, n)
  elif t == TypeTagId: emitType(e, n)
  elif t == VarTagId or t == LetTagId or t == ConstTagId or t == GvarTagId or
       t == GletTagId or t == ResultTagId or t == CursorTagId: emitLocal(e, n)
  elif t == RaiseTagId:
    inc n
    if n.kind == DotToken:                        # `(raise .)` -> re-raise
      e.emit("throw " & (if curCatchVar.len > 0: curCatchVar else: "new Error()") & ";")
      inc n
    elif pendingThrow.len > 0:                    # a stashed `exc = newobj`
      e.emit("throw " & pendingThrow & ";"); pendingThrow = ""
      skip n
    else:                                         # bare `raise ErrorCode`
      var nm = ""
      if n.kind == Symbol or n.kind == SymbolDef or n.kind == Ident:
        nm = opName(pool.syms[n.symId])
      e.emit("throw new Error(" & jsString(nm) & ");")
      skip n
    consumeParRi n
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
  elif t == IteratorTagId: emitProc(e, n, isIter = true)
  elif t == YldTagId:
    inc n                                       # (yld VALUE) -> yield VALUE;
    e.emit("yield "); emitExpr(e, n, curRetBig); e.emit(";")
    consumeParRi n
  else: skip n

proc scanExcTypes(n: var Cursor) =
  ## walk the tree; record every object type transitively inheriting `Exception`
  ## (base is `Exception…`, or another already-recorded exception object type) so
  ## it is later emitted as a real JS class. Base types precede derived ones in the
  ## decl order nimony emits, so a single forward pass resolves the chain.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == TypeTagId:
    var c = n
    inc c                                # NAME
    let nm = if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
               mangle(pool.syms[c.symId]) else: ""
    inc c                                # past NAME -> export/typevars/pragmas…
    while c.kind != ParRi and not (c.kind == ParLe and c.tagEnum == ObjectTagId):
      skip c                             # skip export, typevars, pragmas to the body
    if nm.len > 0 and c.kind == ParLe and c.tagEnum == ObjectTagId:
      inc c                              # -> BASE (sym) | `.`
      if c.kind == Symbol or c.kind == SymbolDef or c.kind == Ident:
        let baseNm = pool.syms[c.symId]
        if opName(baseNm) == "Exception":
          excClassNames.add nm; excClassBase.add "Error"
        elif isExcClass(mangle(baseNm)):
          excClassNames.add nm; excClassBase.add mangle(baseNm)
    skip n
  else:
    inc n
    while n.kind != ParRi: scanExcTypes(n)
    consumeParRi n

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
  if n.tagEnum == ProcTagId or n.tagEnum == FuncTagId or n.tagEnum == IteratorTagId:
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

proc jsPrelude*(): string =
  ## the once-per-program runtime shim (echo capture, float print, seq/str append,
  ## and — in faithful mode — the 64-bit bigint wrappers).
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  e.emit("function __wf(x){ __out += (Number.isInteger(x) ? x + '.0' : String(x)); }\n")
  e.emit("function __sf(x){ return Number.isInteger(x) ? x + '.0' : String(x); }\n")
  if faithfulMode:
    # faithful: a bare int literal argument is a `number`, but the seq may hold
    # `bigint` elements — coerce so a later `sum + xs[i]` doesn't mix the two.
    e.emit("function __append(c, x){ if(typeof c === 'string') return c + x; " &
           "if(typeof x === 'number' && c.length > 0 && typeof c[0] === 'bigint') x = BigInt(x); " &
           "c.push(x); return c; }\n")
  else:
    e.emit("function __append(c, x){ if(typeof c === 'string') return c + x; c.push(x); return c; }\n")
  if faithfulMode:
    # faithful-export runtime: 64-bit ints are JS `bigint`; wrap arithmetic to the
    # exact two's-complement width and guard integer division. (echo prints a bigint
    # via String(x), i.e. "5" not "5n", so no writer change is needed.)
    e.emit("const _i64 = (x) => BigInt.asIntN(64, x);\n")
    e.emit("const _u64 = (x) => BigInt.asUintN(64, x);\n")
    e.emit("const _idiv = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a / b; };\n")
    e.emit("const _imod = (a, b) => { if (b === 0n) throw new Error(\"DivByZero\"); return a % b; };\n")
  result = e.js

proc jsFlush*(): string =
  ## return the captured output once, at the end. (`return` at module top level is
  ## legal — Node wraps every module file in a function.)
  result = "\nreturn __out;\n"

proc emitModuleBody*(root: var Cursor): string =
  ## emit ONE module's JS (no prelude/flush): procs float up (JS hoists function
  ## decls), top-level statements run at module scope. Enum-ordinal and var/out
  ## param scans accumulate into the shared tables so cross-module calls resolve.
  var scanCur = root
  scanEnums(scanCur)
  var scanCur2 = root
  scanProcBoxed(scanCur2)
  var scanCur3 = root
  scanExcTypes(scanCur3)
  var e = JsEmitter(js: "")
  emitStmt(e, root)
  result = e.js

proc emitModule*(root: var Cursor): string =
  ## single-module convenience: full standalone JS (prelude + body + flush).
  result = jsPrelude() & emitModuleBody(root) & jsFlush()
