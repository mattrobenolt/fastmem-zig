# fastmem: fast memcpy/memmove/memset for Zig. README.md and AGENTS.md
# describe the layout; docs/bench-design.md describes the benchmark system.

default: test

# Unit tests, the export-layer checks, and the shipped-binary builds
test:
    zig build test

# The export-layer binary checks alone (docs/export-layer.md)
test-export:
    zig build test-export

# The full guard-page correctness matrix on this host (G1)
test-guard:
    zig build test-guard -Doptimize=ReleaseFast

# x86 codegen gates for all fleet CPU models (runs on any host)
codegen-x86:
    zig build codegen-x86

# Zig 0.16: --fuzz takes an iteration budget with a K/M/G suffix, not a
# duration. ReleaseSafe forces the LLVM backend, dodging the 0.16.0
# self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655).
# Run the fuzzer with an iteration budget (e.g. just fuzz 50M)
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

# Run the measurement binary on this host (e.g. just bench --suite quick --filter copy/aligned)
bench *ARGS:
    zig build bench -- {{ ARGS }}

# Emit assembly and LLVM IR for the native (or -Dtarget) target into zig-out/asm/
asm *ARGS:
    zig build asm {{ ARGS }}
    @ls zig-out/asm/

# Emit assembly for the linux-gnu/musl and macOS triples
asm-all:
    zig build asm-all
    @ls zig-out/asm/

# Show one function from the native assembly (e.g. just show-fn fastmem_copy)
show-fn FN:
    @grep -A 80 '{{ FN }}:' zig-out/asm/*.s

# Compare assembly between two triples (run asm-all first)
diff-asm A B:
    diff --color zig-out/asm/{{ A }}.s zig-out/asm/{{ B }}.s || true

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache

# Benchmark fleet: the bench/ harness (docs/bench-design.md, infra/README.md).
# Every fleet command runs as the fastmem-bench IAM user.
export AWS_PROFILE := env("AWS_PROFILE", "fastmem-bench")

# Run any harness command (e.g. just b ls, just b up c8g c7i --ttl 2h, just b analyze <run-dir>)
b *ARGS:
    uv run --project bench bench {{ ARGS }}

# Launch boxes (e.g. just bench-up c8g c7i, or just bench-up for every target)
bench-up *TARGETS:
    uv run --project bench bench up {{ if TARGETS == "" { "c7i c8i c7a c8a c7g c8g c9g" } else { TARGETS } }}

# Terminate every box of this project
bench-down:
    uv run --project bench bench down --all

# Show the fleet
bench-ls:
    uv run --project bench bench ls

# Correctness on every running box (e.g. just bench-test --optimize ReleaseFast --optimize Debug)
bench-test *ARGS:
    uv run --project bench bench test {{ ARGS }}

# Measure on every running box (e.g. just bench-run --rev main --rev WORKTREE --suite standard)
bench-run *ARGS:
    uv run --project bench bench run {{ ARGS }}

# Harness checks: tests, lint, format, types
bench-check:
    cd bench && uv run pytest -q && uv run ruff check . && uv run ruff format --check . && uv run ty check

# Apply the durable base (security group, key pair, launch templates)
bench-base:
    tofu -chdir=infra/base init -input=false
    tofu -chdir=infra/base apply
