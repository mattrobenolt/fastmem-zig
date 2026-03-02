#!/usr/bin/env nu

const ORB_PREFIX = "fastmem-bench"
const TAG_PREFIX = "fastmem-bench"

const SSH_OPTS = [
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "LogLevel=ERROR"
]

const AWS_INSTANCE_NAMES = ["c7i" "c7a" "c8g"]
const ORB_INSTANCE_NAMES = ["orb-arm64"]

def project-dir [] {
    $env.FILE_PWD | path dirname
}

def infra-dir [] {
    [(project-dir) "infra"] | path join
}

def results-dir [] {
    [(project-dir) "bench-results"] | path join
}

def rsync-excludes [] {
    ["--exclude" ".direnv" "--exclude" ".zig-cache" "--exclude" "zig-out"
     "--exclude" ".claude" "--exclude" "bench-results" "--exclude" ".git"]
}

# Get a single tofu output as JSON
def tofu-output [name: string] {
    let result = (do { ^tofu -chdir=(infra-dir) output -json $name } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to read tofu output '($name)'. Have you run 'tofu init' and 'tofu apply'?\n($result.stderr)" }
    }
    $result.stdout | from json
}

def ssh-key-file [] {
    tofu-output "ssh_key_file"
}

# ── Target resolution ──────────────────────────────────────────────

def all-target-names [] {
    ["local"] | append $ORB_INSTANCE_NAMES | append $AWS_INSTANCE_NAMES
}

# Returns { ssh_dest, remote_dir, ssh_opts }
def resolve-target [name: string] {
    if $name in $ORB_INSTANCE_NAMES {
        return {
            ssh_dest: $"matt@($ORB_PREFIX)-($name)@orb"
            remote_dir: "/home/matt/fastmem-zig"
            ssh_opts: []
        }
    }

    if $name in $AWS_INSTANCE_NAMES {
        let instances = (tofu-output "instances")
        let inst = ($instances | get -o $name)
        if $inst == null {
            error make { msg: $"Instance ($name) not found in tofu output. Have you run 'tofu apply'?" }
        }
        let ip = ($inst | get public_ip)
        if $ip == null or $ip == "" {
            error make { msg: $"Instance ($name) has no public IP" }
        }

        return {
            ssh_dest: $"root@($ip)"
            remote_dir: "/root/fastmem-zig"
            ssh_opts: [...$SSH_OPTS "-i" (ssh-key-file)]
        }
    }

    error make { msg: $"Unknown target: ($name)" }
}

def target-sync [name: string] {
    let t = (resolve-target $name)
    print $"[($name)] Syncing to ($t.ssh_dest):($t.remote_dir)..."
    let ssh_cmd = if ($t.ssh_opts | length) > 0 {
        ["ssh" ...$t.ssh_opts] | str join " "
    } else {
        "ssh"
    }
    ^rsync -az ...(rsync-excludes) -e $ssh_cmd $"(project-dir)/" $"($t.ssh_dest):($t.remote_dir)/"
    print $"[($name)] Done."
}

def target-bench [name: string, out_dir: string] {
    if $name == "local" {
        local-bench $out_dir
        return
    }

    let t = (resolve-target $name)

    print $"=== [($name)] Syncing ==="
    target-sync $name

    let remote_results = $"($t.remote_dir)/bench-results"
    let ssh_cmd = if ($t.ssh_opts | length) > 0 {
        ["ssh" ...$t.ssh_opts] | str join " "
    } else {
        "ssh"
    }

    print $"=== [($name)] Running tests ==="
    ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && nix develop --command just test"

    print $"=== [($name)] Running bench ==="
    ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && mkdir -p bench-results && nix develop --command just bench > bench-results/bench.txt 2>&1"

    print $"=== [($name)] Running bench-libc ==="
    ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && nix develop --command just bench-libc > bench-results/bench-libc.txt 2>&1"

    print $"=== [($name)] Fetching results ==="
    ^rsync -az -e $ssh_cmd $"($t.ssh_dest):($remote_results)/bench.txt" $"($out_dir)/($TAG_PREFIX)-($name).txt"
    ^rsync -az -e $ssh_cmd $"($t.ssh_dest):($remote_results)/bench-libc.txt" $"($out_dir)/($TAG_PREFIX)-($name)-libc.txt"

    print $"=== [($name)] Complete ==="
}

def local-bench [out_dir: string] {
    print "=== [local] Running tests ==="
    let test_out = (do { cd (project-dir); ^zig build test } | complete)
    print $test_out.stdout
    if $test_out.stderr != "" { print $test_out.stderr }
    if $test_out.exit_code != 0 {
        error make { msg: "[local] Tests failed, skipping benchmarks" }
    }

    print "=== [local] Running bench ==="
    let bench_out = (do { cd (project-dir); ^zig build bench -- } | complete)
    print $bench_out.stdout
    if $bench_out.stderr != "" { print $bench_out.stderr }
    ($bench_out.stdout + $bench_out.stderr) | save -f $"($out_dir)/($TAG_PREFIX)-local.txt"

    print "=== [local] Running bench-libc ==="
    let libc_out = (do { cd (project-dir); ^zig build bench -Dlink-libc=true -- } | complete)
    print $libc_out.stdout
    if $libc_out.stderr != "" { print $libc_out.stderr }
    ($libc_out.stdout + $libc_out.stderr) | save -f $"($out_dir)/($TAG_PREFIX)-local-libc.txt"

    print "=== [local] Complete ==="
}

# ── Infrastructure commands (via OpenTofu) ─────────────────────────

# SSH into a target. Pass remote command as a quoted string, e.g.: bench.nu ssh c7i "uname -m"
def "main ssh" [
    name: string       # Target name (e.g. c7i, c7a, c8g, orb-arm64)
    cmd?: string       # Optional remote command to run (quote the whole thing)
] {
    let t = (resolve-target $name)
    if $cmd != null {
        ^ssh ...$t.ssh_opts $t.ssh_dest $cmd
    } else {
        ^ssh ...$t.ssh_opts $t.ssh_dest
    }
}

# Rsync project to target(s)
def "main sync" [
    name: string = "all"  # Target name or "all"
] {
    let targets = if $name == "all" { all-target-names } else { [$name] }
    $targets | par-each { |n| target-sync $n }
    null
}

# Sync + run benchmarks on target(s)
def "main run" [
    name: string = "all"  # Target name or "all"
    --tag: string = ""    # Tag for organizing results into subdirectories
] {
    let out_dir = if $tag != "" {
        [(results-dir) $tag] | path join
    } else {
        results-dir
    }
    mkdir $out_dir

    let targets = if $name == "all" { all-target-names } else { [$name] }
    $targets | par-each { |n| target-bench $n $out_dir }

    print $"\nResults in ($out_dir)/"
    ls $out_dir
}

# Compare two tagged benchmark runs
def "main compare" [
    baseline: string     # Baseline tag
    candidate: string    # Candidate tag
    target?: string      # Optional: only compare this target
] {
    let base_dir = [(results-dir) $baseline] | path join
    let cand_dir = [(results-dir) $candidate] | path join

    if not ($base_dir | path exists) {
        error make { msg: $"Baseline directory not found: ($base_dir)" }
    }
    if not ($cand_dir | path exists) {
        error make { msg: $"Candidate directory not found: ($cand_dir)" }
    }

    # Discover targets from baseline
    let targets = (ls $base_dir
        | where name =~ "fastmem-bench-"
        | get name
        | each { path basename }
        | each { str replace ".txt" "" | str replace "fastmem-bench-" "" | str replace "-libc" "" }
        | uniq)

    let targets = if $target != null {
        $targets | where { $in == $target }
    } else {
        $targets
    }

    let bold = (ansi attr_bold)
    let reset = (ansi reset)

    print $"\n($bold)Comparing: ($baseline) -> ($candidate)($reset)\n"

    for t in $targets {
        for suffix in ["" "-libc"] {
            let label = if $suffix == "" { $"Target: ($t)" } else { $"Target: ($t) \(libc)" }
            let base_file = [$base_dir $"fastmem-bench-($t)($suffix).txt"] | path join
            let cand_file = [$cand_dir $"fastmem-bench-($t)($suffix).txt"] | path join

            if not ($base_file | path exists) or not ($cand_file | path exists) {
                continue
            }

            print $"\n($bold)($label)  implementation comparison [builtin fastmem libc]($reset)"
            ^benchstat -table .file -row .name,/profile,/dir,/gap,/size -col /impl $base_file $cand_file

            print $"\n($bold)($label)  baseline vs candidate per implementation($reset)"
            ^benchstat -table /impl -row .name,/profile,/dir,/gap,/size -col .file $base_file $cand_file
        }
    }
    print ""
}

def main [] {
    print "Usage: bench.nu <command>

Commands:
  ssh <name>      SSH into a target
  sync [name]     Rsync project to target(s) (default: all)
  run [name] [--tag TAG]  Sync + run benchmarks on target(s) (default: all)
  compare <baseline> <candidate> [target]  Compare tagged runs

Targets:
  local           Local machine (no SSH, runs zig build directly)
  orb-arm64       OrbStack NixOS VM (aarch64, Apple Silicon native)
  c7i             AWS c7i.large (Intel Sapphire Rapids)
  c7a             AWS c7a.large (AMD Genoa)
  c8g             AWS c8g.large (Graviton4)"
}
