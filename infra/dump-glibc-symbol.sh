#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
    echo "usage: $0 <label> <lib-path> <symbol> <start> <stop> <out-file>" >&2
    exit 64
fi

label="$1"
lib_path="$2"
symbol="$3"
start_addr="$4"
stop_addr="$5"
out_file="$6"

if command -v objdump >/dev/null 2>&1; then
    objdump_bin="objdump"
elif command -v llvm-objdump >/dev/null 2>&1; then
    objdump_bin="llvm-objdump"
else
    echo "objdump not found" >&2
    exit 127
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

if [[ -n "$symbol" ]]; then
    if ! "$objdump_bin" -d --no-show-raw-insn --disassemble="$symbol" "$lib_path" >"$tmp_file" 2>/dev/null; then
        : >"$tmp_file"
    fi
fi

if ! grep -Eq '^[[:space:]]*[0-9A-Fa-f]+:' "$tmp_file" 2>/dev/null; then
    "$objdump_bin" -d --no-show-raw-insn --start-address="$start_addr" --stop-address="$stop_addr" "$lib_path" >"$tmp_file"
fi

first_symbol_line="$(
    awk '
    /^[0-9A-Fa-f]+ <.*>:/ {
      print NR ":" $0
      exit
    }
  ' "$tmp_file"
)"

resolved_symbol=""
body_start=1
body_stop=0

if [[ -n "$first_symbol_line" ]]; then
    line_no="${first_symbol_line%%:*}"
    header="${first_symbol_line#*:}"
    resolved_symbol="$(printf '%s\n' "$header" | sed -E 's/^[0-9A-Fa-f]+ <([^>]+)>:$/\1/')"
    body_start=$((line_no + 1))
    next_symbol_line="$(
        awk -v start="$line_no" '
      NR > start && /^[0-9A-Fa-f]+ <.*>:/ {
        print NR
        exit
      }
    ' "$tmp_file"
    )"
    if [[ -n "$next_symbol_line" ]]; then
        body_stop=$((next_symbol_line - 1))
    fi
fi

{
    printf '%s:\n' "$label"
    if [[ -n "$resolved_symbol" ]]; then
        printf '# resolved_symbol: %s\n' "$resolved_symbol"
    fi
    awk -v start="$body_start" -v stop="$body_stop" '
    NR < start { next }
    stop > 0 && NR > stop { next }
    /^Disassembly of section / { next }
    /^[[:space:]]*$/ { next }
    /^[0-9A-Fa-f]+ <.*>:/ { next }
    /^[[:space:]]*[0-9A-Fa-f]+:/ { print }
  ' "$tmp_file"
} >"$out_file"
