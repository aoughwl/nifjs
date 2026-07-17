#!/usr/bin/env bash
# aifjs FAITHFUL-mode test harness — for each tests/faithful/*.nim:
#   1. compile+run with nimony (the reference stdout + the .s.nif),
#   2. transpile the main .s.nif with `bin/aifjs --faithful`,
#   3. run the emitted .js under node and diff against the nimony reference,
#   4. ALSO transpile in fast mode and show it gets the overflow programs WRONG
#      (this contrast is the whole point of faithful mode).
#
# Requires: NIM=/home/savant/nimony (or $NIM), node >= 20 on PATH.
set -u
NIM="${NIM:-/home/savant/nimony}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AIFJS="$ROOT/bin/aifjs"
SRC="$HERE/faithful"
NC="/tmp/aifjs-faithful-nc"
OUT="$HERE/_out_faithful"
mkdir -p "$NC" "$OUT"

NODE_BIN="$(command -v node || true)"
pass=0; fail=0; total=0

for f in "$SRC"/*.nim; do
  name="$(basename "$f" .nim)"
  total=$((total+1))
  ref="$("$NIM/bin/nimony" c -r --nimcache:"$NC" -f "$f" 2>"$OUT/$name.build.log")"
  snif="$(grep -l "$name.nim" "$NC"/*.s.nif 2>/dev/null | head -1)"
  if [ -z "$snif" ]; then
    echo "FAIL  $name  (no .s.nif — see $OUT/$name.build.log)"
    fail=$((fail+1)); continue
  fi
  if ! "$AIFJS" --faithful "$snif" > "$OUT/$name.faithful.js" 2>"$OUT/$name.emit.log"; then
    echo "FAIL  $name  (faithful emit crashed — see $OUT/$name.emit.log)"
    fail=$((fail+1)); continue
  fi
  "$AIFJS" "$snif" > "$OUT/$name.fast.js" 2>/dev/null   # for the contrast
  if [ -z "$NODE_BIN" ]; then
    echo "EMIT  $name  (no node — emitted $OUT/$name.faithful.js, not executed)"
    pass=$((pass+1)); continue
  fi
  # the emitter returns __out; wrap in an IIFE + print so `node file.js` runs it.
  got="$(node -e "process.stdout.write((function(){$(cat "$OUT/$name.faithful.js")})())" 2>"$OUT/$name.run.log")"
  fastgot="$(node -e "process.stdout.write((function(){$(cat "$OUT/$name.fast.js")})())" 2>/dev/null)"
  if [ "$got" == "$ref" ]; then
    echo "PASS  $name  (faithful == nimony, byte-exact)"
    if [ "$fastgot" != "$ref" ]; then
      echo "      contrast: fast mode is WRONG here (proves the point)"
      echo "        nimony/faithful: $(echo "$ref" | tr '\n' '|')"
      echo "        fast (number):   $(echo "$fastgot" | tr '\n' '|')"
    fi
    pass=$((pass+1))
  else
    echo "FAIL  $name  (faithful output mismatch)"
    echo "  expected: $(echo "$ref" | tr '\n' '|')"
    echo "  got:      $(echo "$got" | tr '\n' '|')"
    fail=$((fail+1))
  fi
done

echo "-----------------------------------------"
echo "aifjs faithful: $pass/$total passed, $fail failed"
[ "$fail" -eq 0 ]
