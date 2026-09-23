---
name: zig
description: "Write correct, idiomatic Zig 0.16 code in this repository (pins zig 0.16.0). Triggers on any task involving .zig files, build.zig.zon, or Zig compile errors here. LLM training data is based on Zig 0.11-0.15 and produces broken code against 0.16; this skill holds patterns verified against this repo's exact toolchain. Project-local skill; shadows the global 0.15-era 'zig' skill in this repo."
---

# Zig 0.16 (this repo)

This repo builds with zig 0.16.0 (nix flake, `zig_0_16`; minimum_zig_version in
build.zig.zon is 0.16.0). Training data covers 0.11-0.15 at best. The 0.15-era
patterns (the global `zig` skill) are **wrong here** in specific, silent ways —
mostly around `std.Io`, `std.time`, `main`'s signature, and `std.testing.fuzz`.

Rule zero: verify APIs against the pinned toolchain, not memory.

```bash
zigdoc std.Io.File          # API discovery, toolchain-aware
zig env                     # .std_dir = actual std source for THIS zig
ziglint src/                # style + correctness lint
grep -n "pub fn find" "$(zig env | ...)"   # or grep $STD directly
```

`zig env` prints `.std_dir` — grep that tree when a signature matters. It is
the source of truth, and it is cheap.

## Critical changes you will get wrong

### 1. `main` takes `std.process.Init` ("Juicy Main")

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;                          // general purpose allocator, threadsafe
    const io = init.io;                            // default Io implementation
    const arena: std.mem.Allocator = init.arena.allocator();  // process-lifetime, threadsafe, auto-freed
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // init.environ_map: *Environ.Map — env vars are NOT global anymore
    // init.preopens: Preopens
}
```

- argv and environ exist **only** through this parameter. `std.process.environ`
  and global argv access are gone. Empty param list `pub fn main() !void` is
  legal but then you get no args/env.
- `std.process.Init.Minimal` is the smaller variant (argv + environ only).
- Use `std.testing.io` in tests, like `std.testing.allocator`.
- This repo's examples: `src/bench_fastmem.zig` (threads `init.io` into the
  timing harness), `src/libc_probe.zig` (buffered stdout writer).

### 2. I/O as an Interface — everything takes `Io`

`std.fs.File` → `std.Io.File`. `std.fs.Dir` → `std.Io.Dir`. `std.fs.cwd()` →
`std.Io.Dir.cwd()`. `file.close()` → `file.close(io)`.

```zig
// stdout, buffered (from this repo's src/libc_probe.zig — it compiles):
var buffer: [4096]u8 = undefined;
var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
const stdout = &stdout_file_writer.interface;
try stdout.writeByte('\n');
try stdout.flush();            // still required — output stays buffered otherwise

// FixedBufferStream is gone:
var writer: std.Io.Writer = .fixed(buffer);        // was fixedBufferStream
var reader: std.Io.Reader = .fixed(data);
```

- Functions that do I/O take `Io` (by value) or `*Io`. Thread `Io` through the
  call chain; do not conjure globals. (For pure timing, this repo passes
  `io: Io` as a plain function argument after comptime params — see
  `runCopyOnce` in `src/bench_fastmem.zig`.)
- `Io.Timestamp.now(io, .awake)` is the monotonic clock: `start.durationTo(
  Io.Timestamp.now(io, .awake)).nanoseconds` (i96) gives elapsed ns.
  `std.time.Timer` and `std.time.Instant` are gone.
- `std.net` → `std.Io.net`.
- Io implementations: `Io.Threaded` is complete (default for `init.io`);
  `Io.Evented`/`Io.Uring`/`Io.Kqueue` are WIP/proof-of-concept.

### 3. `std.posix` was gutted — 54 functions left

The medium layer was removed. Survivors include `read`, `mmap`/`munmap`/
`mremap`/`msync`, `kill`/`raise`, `openat`, `sched_getaffinity`, the sigset
helpers, `sigaltstack`. Everything else: go **higher** (`std.Io`) or **lower**
(`std.posix.system` — which is `std.os.linux` without libc, `std.c` with libc).
Decode raw returns yourself: `linux.E` is an `enum(u16)`, not an error set.

### 4. `std.testing.fuzz` takes a Smith, not bytes

```zig
try testing.fuzz({}, struct {
    fn run(_: void, smith: *testing.Smith) anyerror!void {
        const len: usize = smith.value(u8);              // or valueRangeAtMost(u8, 0, 200)
        const fill: u8 = smith.value(u8);
        var buf: [512]u8 = undefined;
        smith.bytes(buf[0..len]);                        // fill from the input stream
        // ...
    }
}.run, .{ .corpus = &.{ "", &.{ 64, 'a', 'b', 'c' } } });
```

- Old `fn (ctx, input: []const u8)` callbacks no longer compile.
- Named enum types only — `smith.value(enum {...})` twice creates two distinct
  anonymous types; hoist a `const Direction = enum {...}` first.
- `--fuzz` now takes an iteration budget with a K/M/G suffix, not a duration.
- **0.16.0 toolchain bug**: fuzz mode fails to compile in Debug
  (ziglang/zig#30655, self-hosted backend). Run `zig build test
  -Doptimize=ReleaseSafe --fuzz=...` (LLVM backend) — see `just fuzz`.

### 5. `std.mem` renames — "index of" is now "find"

`indexOf` → `find`, `indexOfScalar` → `findScalar`, `lastIndexOf` → `findLast`,
`indexOfPos` → `findPosLinear` family. New cut helpers: `cut`, `cutPrefix`,
`cutSuffix`, `cutScalar`, `cutLast`, `cutLastScalar`. Emitting
`std.mem.indexOf*` is a compile error now.

### 6. Other 0.16 breaks, one line each

- `@Type` removed → `@Int(.unsigned, 10)`, `@Struct`, `@Union`, `@Enum`,
  `@Pointer`, `@Fn`, `@Tuple`, `@EnumLiteral()`.
- `@cImport` deprecated (still compiles) → `b.addTranslateC` in build.zig.
  This repo still uses `@cImport` in `src/libc_probe.zig` for `dlfcn.h`.
- Sync primitives moved: `Thread.ResetEvent`→`Io.Event`, `WaitGroup`→`Io.Group`,
  `Futex`→`Io.Futex`, `Mutex`→`Io.Mutex`, `Condition`→`Io.Condition`,
  `Semaphore`→`Io.Semaphore`. `std.once` and `Thread.Pool` removed.
  `ArenaAllocator` is threadsafe/lock-free; `ThreadSafeAllocator` removed.
- `Compile.linkSystemLibrary` is gone — call `module.linkSystemLibrary("dl",
  .{})` on the Module, not the artifact (see libc-probe in `build.zig`).
- Entropy: `std.crypto.random.bytes` → `io.random(&buf)`; Random via
  `std.Random.IoSource{ .io = io }`.
- Time: `std.time.Instant`/`Timer` → `std.Io.Timestamp`. `{D}` format
  specifier removed → `{f}` with `std.Io.Duration`.
- Floats: small ints (`u24`→`f32`) coerce implicitly; `@floor/@ceil/@round/
  @trunc` convert to int directly; `@intFromFloat` deprecated.
- Managed containers removed (`AutoArrayHashMap` → `array_hash_map.Auto`,
  etc.); `BitSet`/`EnumSet` use `.empty`/`.full` decl literals.
- Returning the address of a local is a compile error.
- Pointers forbidden in `packed struct`/`packed union`.
- Runtime vector indexing forbidden — coerce to array first.
- fmt: `Formatter`→`Alt`, `bufPrintZ`→`bufPrintSentinel`.
- Error renames: `RenameAcrossMountPoints`/`NotSameFileSystem`→`CrossDevice`,
  `SharingViolation`→`FileBusy`, `EnvironmentVariableNotFound`→
  `EnvironmentVariableMissing`.
- Child processes: `std.process.spawn(io, .{ .argv, .stdin, ... })`,
  `std.process.run(allocator, io, .{...})`, `std.process.replace(io, ...)`.

Full detail with examples: [references/zig-0.16-changes.md](references/zig-0.16-changes.md).

### 7. Unchanged from 0.15, still easy to get wrong

- `std.ArrayList` is unmanaged: init `.empty`, allocator per mutating call
  (`list.append(allocator, item)`), `list.deinit(allocator)`.
- Cast builtins are single-argument, return type inferred from context:
  `const x: DestType = @ptrCast(ptr);`
- Type reflection tags lowercase: `.int`, `.float`, `.@"struct"`, `.@"enum"`.
- Structs/arrays have no `==`; use `std.meta.eql` / `std.mem.eql`.
- `@splat` for uniform array/vector init; `@memcpy`/`@memmove`/`@memset`
  builtins are the comparison baseline this library fights against.

## Security footgun: narrow-type arithmetic in bounds checks

Zig evaluates `narrow_type + comptime_int` in the narrow type **before**
widening for the comparison. A bounds check like:

```zig
const len = r.assumeRead(u16);           // attacker-controlled length
if (remaining < len + 5) return error.UnexpectedEof;   // BUG: overflows u16
```

panics (Debug/ReleaseSafe) or is UB (ReleaseFast) before the comparison
rejects the oversized input. Remote DoS class on any parser that reads an
attacker-controlled length field. Always widen first:

```zig
if (remaining < @as(usize, len) + 5) return error.UnexpectedEof;
```

Audit every `narrow_var + comptime_int` bounds check when writing or reviewing
record parsing. Not currently applicable to fastmem (no untrusted lengths),
but keep it in mind for any future parsing surface.

## Style

Matt's style rules (expression shape, enums-over-bools, buffers, arithmetic
placement, file-as-a-struct): [references/matt-zig-style.md](references/matt-zig-style.md) — apply when
writing or reviewing any Zig here.

- `camelCase` functions, `snake_case` variables/constants, `PascalCase` types.
- Prefer `const foo: Type = .{ .field = value };` over `const foo = Type{...};`.
- comptime params first, then `Io`/allocator, then runtime args (ziglint Z023
  enforces comptime-first).
- Tests inline with the code they cover; `ziglint src/` before calling it done.
- Comments explain why, not what.

## Before writing Zig code

1. `zigdoc <symbol>` for any std API you are not certain of — 0.16 renamed too
   much to guess.
2. Read existing code in `src/` first; match established patterns.
3. Grep the pinned std source (`zig env` → `.std_dir`) when a signature matters.
4. After writing, run BOTH `zig build test` AND `zig build` — lazy analysis can
   leave a non-test entry's call graph unanalyzed.
5. Use `just` recipes where they exist (`just fuzz`, `just bench`); prefer them
   over raw zig build invocations.
