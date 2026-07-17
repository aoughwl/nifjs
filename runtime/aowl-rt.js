// aowl-rt.js — the aifjs faithful-export numeric runtime.
//
// aifjs `--faithful` mode maps every width-64 Nimony integer (`int`, `int64`,
// `uint`, `uint64`) to a JS `bigint`, so values past 2^53 and int64/uint64
// overflow stay exact instead of silently rounding as they do in the default
// `number`-based fast mode.
//
// Emitted programs inline these four helpers into their prelude so they run
// standalone under Node (`node out.js`) with no import. This module is the same
// four helpers as a real import, for projects that prefer to share one copy:
//
//     import { _i64, _u64, _idiv, _imod } from "./runtime/aowl-rt.js";
//
// _i64 / _u64 clamp a bigint back into the signed / unsigned two's-complement
// 64-bit range (exactly Nim's wrap-around semantics). _idiv / _imod are integer
// division and modulo; bigint `/` and `%` already truncate toward zero like Nim,
// so these only add the DivByZero guard.

/** Wrap a bigint into the signed 64-bit range (int / int64). */
export const _i64 = (x) => BigInt.asIntN(64, x);

/** Wrap a bigint into the unsigned 64-bit range (uint / uint64). */
export const _u64 = (x) => BigInt.asUintN(64, x);

/** Integer division (truncating toward zero), with a Nim-style DivByZero check. */
export const _idiv = (a, b) => {
  if (b === 0n) throw new Error("DivByZero");
  return a / b;
};

/** Integer modulo (sign follows the dividend), with a Nim-style DivByZero check. */
export const _imod = (a, b) => {
  if (b === 0n) throw new Error("DivByZero");
  return a % b;
};
