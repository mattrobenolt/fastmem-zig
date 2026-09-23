# Default: run tests
default: test

# Run all tests
test:
    zig build test

# Run benchmarks (no libc)
bench *ARGS:
    zig build bench -- {{ ARGS }}

# Run benchmarks with libc linked for comparison
bench-libc *ARGS:
    zig build bench -Dlink-libc=true -- {{ ARGS }}

# Emit assembly for the native target
asm:
    zig build asm
    @echo "Output: zig-out/asm/"
    @ls zig-out/asm/

# Emit assembly for all key targets
asm-all:
    zig build asm-all
    @echo "Output: zig-out/asm/"
    @ls zig-out/asm/

# Emit assembly for a specific target (e.g., just asm-target x86_64-linux-gnu)
asm-target TARGET:
    zig build asm -Dtarget={{ TARGET }}
    @echo "Output: zig-out/asm/"
    @ls zig-out/asm/

# Show a specific function from native asm (e.g., just show-fn fastmem_copy)
show-fn FN:
    @grep -A 80 '{{ FN }}:' zig-out/asm/*.s

# Run the fuzzer. Zig 0.16: --fuzz takes an iteration budget with a K/M/G
# suffix, not a duration. ReleaseSafe forces the LLVM backend, dodging the
# 0.16.0 self-hosted-backend bug in Debug fuzz mode (ziglang/zig#30655).
fuzz LIMIT="10M":
    zig build test -Doptimize=ReleaseSafe --fuzz={{ LIMIT }}

# Cross-compile benchmarks for a target with libc
bench-cross TARGET *ARGS:
    zig build bench -Dtarget={{ TARGET }} -Dlink-libc=true -- {{ ARGS }}

# Compare asm between two targets (run asm-all first)
diff-asm A B:
    diff --color zig-out/asm/{{ A }}.s zig-out/asm/{{ B }}.s || true

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache

# Benchmark fleet: the bench/ harness (docs/bench-design.md, infra/README.md).
# Every fleet command runs as the fastmem-bench IAM user.
export AWS_PROFILE := env("AWS_PROFILE", "fastmem-bench")

# Run a harness command (e.g. just b ls, just b up c8g c7i --ttl 2h)
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

# Run benchmarks on the running boxes (e.g. just bench-run --rev HEAD --rev WORKTREE --suite quick)
bench-run *ARGS:
    uv run --project bench bench run {{ ARGS }}

# Harness checks: tests, lint, format, types
bench-check:
    cd bench && uv run pytest -q && uv run ruff check . && uv run ruff format --check . && uv run ty check

# Apply the durable base (security group, key pair, launch templates)
bench-base:
    tofu -chdir=infra/base init -input=false
    tofu -chdir=infra/base apply
