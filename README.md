# nifjs

The **nimony-native** `.s.nif` → **native-JavaScript** backend.

`nifjs` reads a typed nimony NIF (`.s.nif`) and emits **real JavaScript** — mapping
nimony values onto native JS values (`int`/`float` → number, `string` → string,
`seq` → Array, object → plain object) so the browser's JIT compiles the result.
Near-native speed, readable output.

It is written **in nimony**, the way the rest of the toolchain is (`nifparser`,
`nifsem`, `nifi`, `lengcgen`) — not hand-written in JavaScript. That's the point:
nifjs belongs *inside* the ecosystem, and once nimony can compile it, nifjs can
compile **itself**.

> **Two repos, on purpose.**
> - **`aoughwl/nifjs`** (this one) — the nimony implementation. The real one.
> - **[`aoughwl/nifjs-js`](https://github.com/aoughwl/nifjs-js)** — the original
>   hand-written **JavaScript** implementation. It's the **bootstrap seed** and
>   the differential oracle: it works today, powers the playground's *Native JS*
>   engine, and is what compiles *this* nimony version the first time.

## The one idea

`nifjs` is **[`nifi`](https://github.com/aoughwl/nifi) with the interpreter
swapped for a JavaScript emitter.** nifi is already a nimony program that loads a
`.s.nif` (`parseFromBuffer` → `beginRead` → a `Cursor`) and walks it with a
`case n.tagEnum` dispatch (`execStmt`/`execIf`/`execWhile`/`execCall`/…). nifjs
reuses that entire, tested front-end and changes each handler from *"do the
thing"* to *"append the JavaScript"*:

```
nifi:   of IfTagId:   result = execIf(ip, n)       # run the branch
nifjs:  of IfTagId:   emitIf(e, n)                 # print `if(cond){…}`
```

So we don't re-solve NIF reading, symbol resolution, or the type model — we
inherit them from nifi and write only the emitter.

## Bootstrap — how it self-hosts

```
1. seed:   aoughwl/nifjs-js  (hand-written JS)   .s.nif ─▶ native JS   [works today]
2. write:  aoughwl/nifjs     (this, in nimony)   .s.nif ─▶ native JS
3. compile nifjs.nim with nimony               → nifjs.s.nif
4. run nifjs.s.nif through the JS seed          → a fast, native-JS nifjs   ← self-hosted
```

After step 4 the JS seed is disposable: nifjs compiles itself, `nifparser`,
`nifsem`, and your programs — all to fast native JS, all from nimony source.

**Prerequisite the seed still needs:** to transpile *this* (a nimony program that
uses `Table`/`Cursor`/etc.), the JS seed must cover those. `Table` → JS `Map` is
the main remaining item on the seed; the language surface is otherwise complete.

## Status

**Seed / WIP.** `src/emitjs.nim` holds the emitter skeleton (the tag dispatch,
modeled on nifi's `interp.nim`) and `src/webmain_js.nim` the browser entry
(modeled on nifi's `webmain.nim`). It reuses nifi's front-end, so it builds
alongside a nifi checkout — see the source headers.

## License

MIT — see [LICENSE](LICENSE).
