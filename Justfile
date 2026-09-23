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

# Launch all benchmark targets (OrbStack + AWS)
[working-directory("infra")]
bench-up:
    tofu apply -auto-approve

# Tear down all benchmark targets
[working-directory("infra")]
bench-down:
    tofu destroy -auto-approve

# Show benchmark target status
[working-directory("infra")]
bench-status:
    tofu output

# SSH into a benchmark target (e.g., just bench-ssh c7i, just bench-ssh orb-arm64)
bench-ssh NAME:
    ./infra/bench.nu ssh {{ NAME }}

# Run benchmarks on targets (e.g., just bench-run c8g, just bench-run orb-arm64, or just bench-run for all)
bench-run NAME="all":
    ./infra/bench.nu run {{ NAME }}

# Sync project to targets (e.g., just bench-sync c7a, or just bench-sync for all)
bench-sync NAME="all":
    ./infra/bench.nu sync {{ NAME }}

# Run tagged benchmarks on all targets (e.g., just bench-run-tagged baseline)
bench-run-tagged TAG NAME="all":
    ./infra/bench.nu run {{ NAME }} --tag {{ TAG }}

# Run a saved baseline-vs-worktree trial (e.g., just bench-trial c7i --baseline-ref HEAD --label peel)
bench-trial TARGET="local" *ARGS:
    ./infra/bench.nu trial {{ TARGET }} {{ ARGS }}

# Compare two tagged benchmark runs (e.g., just bench-compare baseline experiment)
bench-compare BASELINE CANDIDATE:
    ./infra/bench.nu compare {{ BASELINE }} {{ CANDIDATE }}

# Initialize OpenTofu (run once after cloning)
[working-directory("infra")]
infra-init:
    tofu init
