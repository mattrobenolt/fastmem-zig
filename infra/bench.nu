#!/usr/bin/env nu

const ORB_PREFIX = "fastmem-bench"
const TAG_PREFIX = "fastmem-bench"

const SSH_OPTS = [
    "-o" "StrictHostKeyChecking=no"
    "-o" "UserKnownHostsFile=/dev/null"
    "-o" "LogLevel=ERROR"
    "-o" "ConnectTimeout=10"
    "-o" "ServerAliveInterval=15"
    "-o" "ServerAliveCountMax=4"
]

const AWS_INSTANCE_NAMES = ["c7i" "c7a" "c8g"]
const AWS_INSTANCE_FALLBACK_SSH_DESTS = {
    c7i: "root@52.24.204.147"
    c7a: "root@44.251.47.18"
    c8g: "root@54.188.244.253"
}
const ORB_INSTANCE_NAMES = ["orb-arm64"]
const ASM_SYMBOLS = ["fastmem_copy" "fastmem_move" "builtin_memcpy" "builtin_memmove" "glibc_memcpy" "glibc_memmove"]
const REMOTE_MIN_FREE_KIB = 4 * 1024 * 1024
const GLIBC_DISASM_WINDOW_BYTES = 1024

def project-dir [] {
    let file_pwd = (($env | get -o FILE_PWD) | default "")
    if $file_pwd == "" {
        $env.PWD
    } else {
        $file_pwd | path dirname
    }
}

def infra-dir [] {
    [(project-dir) "infra"] | path join
}

def results-dir [] {
    [(project-dir) "bench-results"] | path join
}

def asm-baseline-dir [] {
    [(results-dir) "asm-baselines"] | path join
}

def asm-baseline-file [name: string] {
    [(asm-baseline-dir) $"($name).md"] | path join
}

def artifact-dir [out_dir: string, name: string] {
    [$out_dir "artifacts" $name] | path join
}

def host-artifact-dir [out_dir: string, name: string] {
    [(artifact-dir $out_dir $name) "host"] | path join
}

def asm-artifact-dir [out_dir: string, name: string] {
    [(artifact-dir $out_dir $name) "asm"] | path join
}

def asm-raw-dir [out_dir: string, name: string] {
    [(asm-artifact-dir $out_dir $name) "raw"] | path join
}

def asm-symbol-dir [out_dir: string, name: string, kind: string] {
    [(asm-artifact-dir $out_dir $name) "symbols" $kind] | path join
}

def timestamp [] {
    date now | format date "%Y%m%d-%H%M%S"
}

def iso-timestamp [] {
    date now | format date "%Y-%m-%dT%H:%M:%S%:z"
}

def sanitize-label [label: string] {
    let cleaned = ($label
        | str trim
        | str replace -a " " "-"
        | str replace -a "/" "-"
        | str replace -a ":" "-"
        | str replace -a "\\" "-"
        | str replace -a "@" "-"
    )
    if $cleaned == "" { "run" } else { $cleaned }
}

def make-run-id [label: string = ""] {
    let stamp = (timestamp)
    if $label == "" {
        $stamp
    } else {
        $"($stamp)-((sanitize-label $label))"
    }
}

def rsync-excludes [] {
    ["--exclude" ".direnv" "--exclude" ".zig-cache" "--exclude" "zig-out"
     "--exclude" ".claude" "--exclude" "bench-results" "--exclude" ".git"]
}

def remote-retry-delay [attempt: int] {
    if $attempt == 0 {
        2sec
    } else if $attempt == 1 {
        5sec
    } else {
        15sec
    }
}

def rsync-complete-with-retries [label: string, args: list<any>] {
    mut attempt = 0
    loop {
        let result = (do { ^rsync ...$args } | complete)
        if $result.exit_code == 0 {
            return $result
        }
        if $attempt >= 2 {
            return $result
        }
        let delay = (remote-retry-delay $attempt)
        print $"warning: ($label) failed (attempt ($attempt + 1)/3)
($result.stderr)
retrying in ($delay)"
        sleep $delay
        $attempt += 1
    }
}

def ssh-complete-with-retries [label: string, t: record, remote_cmd: string] {
    mut attempt = 0
    loop {
        let result = (do { ^ssh ...$t.ssh_opts $t.ssh_dest $remote_cmd } | complete)
        if $result.exit_code == 0 {
            return $result
        }
        if $attempt >= 2 {
            return $result
        }
        let delay = (remote-retry-delay $attempt)
        print $"warning: ($label) failed (attempt ($attempt + 1)/3)
($result.stderr)
retrying in ($delay)"
        sleep $delay
        $attempt += 1
    }
}

# Get a single tofu output as JSON
def tofu-output [name: string] {
    let result = (do { ^tofu -chdir=(infra-dir) output -json $name } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to read tofu output '($name)'. Have you run 'tofu init' and 'tofu apply'?\n($result.stderr)" }
    }
    $result.stdout | from json
}

def tofu-output-optional [name: string] {
    let result = (do { ^tofu -chdir=(infra-dir) output -json $name } | complete)
    if $result.exit_code != 0 {
        null
    } else {
        $result.stdout | from json
    }
}

def ssh-key-file [] {
    let key_file = (tofu-output-optional "ssh_key_file")
    if $key_file == null or $key_file == "" {
        let fallback = [(infra-dir) "bench.pem"] | path join
        if ($fallback | path exists) {
            print $"warning: ssh_key_file output is unavailable; falling back to cached key ($fallback)"
            $fallback
        } else {
            error make { msg: $"Failed to read tofu output 'ssh_key_file' and cached key ($fallback) is missing." }
        }
    } else {
        $key_file
    }
}

def git-current-head [] {
    let result = (do { cd (project-dir); ^git rev-parse HEAD } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to resolve HEAD.\n($result.stderr)" }
    }
    $result.stdout | str trim
}

def git-rev-parse [ref: string] {
    let result = (do { cd (project-dir); ^git rev-parse $ref } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to resolve git ref '($ref)'.\n($result.stderr)" }
    }
    $result.stdout | str trim
}

def git-branch [] {
    let result = (do { cd (project-dir); ^git branch --show-current } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to determine current branch.\n($result.stderr)" }
    }
    $result.stdout | str trim
}

def git-describe [ref: string = "HEAD"] {
    let result = (do { cd (project-dir); ^git describe --always --tags $ref } | complete)
    if $result.exit_code != 0 {
        return ""
    }
    $result.stdout | str trim
}

def git-subject [ref: string = "HEAD"] {
    let result = (do { cd (project-dir); ^git log -1 --format=%s $ref } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to read commit subject for '($ref)'.\n($result.stderr)" }
    }
    $result.stdout | str trim
}

def git-status-lines [] {
    let result = (do { cd (project-dir); ^git status --short } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to read git status.\n($result.stderr)" }
    }
    if ($result.stdout | str trim) == "" {
        []
    } else {
        $result.stdout | lines
    }
}

def runner-hostname [] {
    let result = (do { ^hostname } | complete)
    if $result.exit_code != 0 {
        return ""
    }
    $result.stdout | str trim
}

def parse-kv-output [text: string] {
    mut facts = {}
    for row in ($text | lines | parse -r '^(?<key>[^=]+)=(?<value>.*)$') {
        $facts = ($facts | upsert $row.key $row.value)
    }
    $facts
}

def host-facts-script [] {
    [
        "set +e"
        "cpu_summary=\"\""
        "if command -v sysctl >/dev/null 2>&1; then cpu_summary=$(sysctl -n machdep.cpu.brand_string 2>/dev/null); fi"
        "if [ -z \"$cpu_summary\" ] && command -v lscpu >/dev/null 2>&1; then cpu_summary=$(lscpu 2>/dev/null | grep -m1 \"Model name:\" | cut -d: -f2- | sed \"s/^ *//\"); fi"
        "os_name=\"\""
        "os_version=\"\""
        "if command -v sw_vers >/dev/null 2>&1; then os_name=$(sw_vers -productName 2>/dev/null); os_version=$(sw_vers -productVersion 2>/dev/null); fi"
        "if [ -z \"$os_name\" ] && [ -r /etc/os-release ]; then . /etc/os-release; os_name=${NAME:-}; os_version=${VERSION_ID:-${VERSION:-}}; fi"
        "printf \"hostname=%s\\n\" \"$(hostname 2>/dev/null || true)\""
        "printf \"uname_s=%s\\n\" \"$(uname -s 2>/dev/null || true)\""
        "printf \"uname_r=%s\\n\" \"$(uname -r 2>/dev/null || true)\""
        "printf \"uname_m=%s\\n\" \"$(uname -m 2>/dev/null || true)\""
        "printf \"cpu_summary=%s\\n\" \"$cpu_summary\""
        "printf \"os_name=%s\\n\" \"$os_name\""
        "printf \"os_version=%s\\n\" \"$os_version\""
        "printf \"zig_version=%s\\n\" \"$(zig version 2>/dev/null || true)\""
        "printf \"just_version=%s\\n\" \"$(just --version 2>/dev/null || true)\""
        "printf \"nix_version=%s\\n\" \"$(nix --version 2>/dev/null || true)\""
    ] | str join "; "
}

def host-report-script [] {
    [
        "set +e"
        "echo \"== host facts ==\""
        (host-facts-script)
        "echo"
        "echo \"== uname -a ==\""
        "uname -a 2>/dev/null || true"
        "echo"
        "if command -v sw_vers >/dev/null 2>&1; then echo \"== sw_vers ==\"; sw_vers; echo; fi"
        "if [ -r /etc/os-release ]; then echo \"== /etc/os-release ==\"; cat /etc/os-release; echo; fi"
        "if command -v lscpu >/dev/null 2>&1; then echo \"== lscpu ==\"; lscpu; echo; fi"
        "if command -v sysctl >/dev/null 2>&1; then echo \"== sysctl cpu ==\"; sysctl -n machdep.cpu.brand_string 2>/dev/null || true; sysctl -n hw.model 2>/dev/null || true; sysctl -n hw.memsize 2>/dev/null || true; echo; fi"
        "if command -v zig >/dev/null 2>&1; then echo \"== zig version ==\"; zig version; echo; fi"
        "if command -v just >/dev/null 2>&1; then echo \"== just --version ==\"; just --version; echo; fi"
        "if command -v nix >/dev/null 2>&1; then echo \"== nix --version ==\"; nix --version; echo; fi"
    ] | str join "; "
}

def local-sh-capture [cwd: string, script: string] {
    do { cd $cwd; ^sh -lc $script } | complete
}

def remote-sh-capture [t: record, script: string] {
    do {
        ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && sh -lc '($script)'"
    } | complete
}

def remote-dev-sh-capture [t: record, script: string] {
    do {
        ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && nix develop --command sh -lc '($script)'"
    } | complete
}

def remote-free-kib [t: record] {
    let result = (do {
        ^ssh ...$t.ssh_opts $t.ssh_dest "df -Pk / | awk 'NR==2 {print \$4}'"
    } | complete)
    if $result.exit_code != 0 {
        error make { msg: $"Failed to read remote free space on ($t.ssh_dest).\n($result.stderr)" }
    }

    let free_text = ($result.stdout | str trim)
    if $free_text == "" {
        error make { msg: $"Remote free space query returned no output for ($t.ssh_dest)" }
    }

    $free_text | into int
}

def remote-maintenance-script [] {
    [
        "set -eu"
        "rm -rf .zig-cache zig-out bench-results"
        "nix-collect-garbage -d"
    ] | str join "; "
}

def ensure-remote-free-space [name: string, t: record] {
    let free_before = (remote-free-kib $t)
    if $free_before >= $REMOTE_MIN_FREE_KIB {
        return
    }

    print $"=== [($name)] Low disk on target; free space is ($free_before) KiB. Running remote cleanup ==="
    let cleanup = (remote-sh-capture $t (remote-maintenance-script))
    if $cleanup.exit_code != 0 {
        error make { msg: $"[($name)] Remote cleanup failed.\n($cleanup.stderr)" }
    }

    let free_after = (remote-free-kib $t)
    print $"=== [($name)] Free space after cleanup: ($free_after) KiB ==="
    if $free_after < $REMOTE_MIN_FREE_KIB {
        error make {
            msg: $"[($name)] Remote host still has insufficient free space after cleanup: ($free_after) KiB free (< ($REMOTE_MIN_FREE_KIB) KiB required)."
        }
    }
}

def collect-local-host-artifacts [name: string, out_dir: string, source_dir: string] {
    let dir = (host-artifact-dir $out_dir $name)
    mkdir $dir

    let facts_file = [$dir "facts.env"] | path join
    let report_file = [$dir "report.txt"] | path join
    let summary_file = [$dir "summary.json"] | path join

    let facts_out = (local-sh-capture $source_dir (host-facts-script))
    ($facts_out.stdout + $facts_out.stderr) | save -f $facts_file

    let report_out = (local-sh-capture $source_dir (host-report-script))
    ($report_out.stdout + $report_out.stderr) | save -f $report_file

    let summary = {
        version: 1
        collected_at: (iso-timestamp)
        target: $name
        mode: "local"
        facts_exit_code: $facts_out.exit_code
        report_exit_code: $report_out.exit_code
        facts_file: $facts_file
        report_file: $report_file
        facts: (parse-kv-output $facts_out.stdout)
    }
    $summary | to json --indent 2 | save -f $summary_file
    $summary
}

def collect-remote-host-artifacts [name: string, out_dir: string, t: record] {
    let dir = (host-artifact-dir $out_dir $name)
    mkdir $dir

    let facts_file = [$dir "facts.env"] | path join
    let report_file = [$dir "report.txt"] | path join
    let summary_file = [$dir "summary.json"] | path join

    let facts_out = (remote-dev-sh-capture $t (host-facts-script))
    ($facts_out.stdout + $facts_out.stderr) | save -f $facts_file

    let report_out = (remote-dev-sh-capture $t (host-report-script))
    ($report_out.stdout + $report_out.stderr) | save -f $report_file

    let summary = {
        version: 1
        collected_at: (iso-timestamp)
        target: $name
        mode: "ssh"
        ssh_dest: $t.ssh_dest
        facts_exit_code: $facts_out.exit_code
        report_exit_code: $report_out.exit_code
        facts_file: $facts_file
        report_file: $report_file
        facts: (parse-kv-output $facts_out.stdout)
    }
    $summary | to json --indent 2 | save -f $summary_file
    $summary
}

def list-newer-files [dir: string, marker_file: string] {
    let result = (do { ^find $dir -maxdepth 1 -type f -newer $marker_file } | complete)
    if $result.exit_code != 0 {
        []
    } else {
        $result.stdout
        | lines
        | each { str trim }
        | where { $in != "" }
        | sort
    }
}

def native-asm-basename-from-facts [facts: record] {
    let machine = (($facts | get -o uname_m) | default "" | str downcase)
    let sysname = (($facts | get -o uname_s) | default "" | str downcase)

    if $sysname == "darwin" and ($machine in ["arm64" "aarch64"]) {
        "aarch64-macos-none"
    } else if $sysname == "linux" and ($machine in ["arm64" "aarch64"]) {
        "aarch64-linux-gnu"
    } else if $sysname == "linux" and ($machine in ["x86_64" "amd64"]) {
        "x86_64-linux-gnu"
    } else {
        ""
    }
}

def fallback-local-asm-files [source_dir: string, native_basename: string] {
    if $native_basename == "" {
        []
    } else {
        let asm_file = [$source_dir "zig-out" "asm" $"($native_basename).s"] | path join
        let ll_file = [$source_dir "zig-out" "asm" $"($native_basename).ll"] | path join
        mut files = []
        if ($asm_file | path exists) {
            $files = ($files | append [$asm_file])
        }
        if ($ll_file | path exists) {
            $files = ($files | append [$ll_file])
        }
        $files
    }
}

def fallback-remote-asm-files [remote_dir: string, native_basename: string] {
    if $native_basename == "" {
        []
    } else {
        let asm_file = [$remote_dir "zig-out" "asm" $"($native_basename).s"] | path join
        let ll_file = [$remote_dir "zig-out" "asm" $"($native_basename).ll"] | path join
        [$asm_file $ll_file]
    }
}

def supports-glibc-disassembly [facts: record] {
    (($facts | get -o uname_s) | default "" | str downcase) == "linux"
}

def sh-quote [value: string] {
    ["'" ($value | str replace -a "'" "'\\''") "'"] | str join ""
}

def normalize-asm-lines [lines: list<string>] {
    let skip_pattern = '^\s*(\.cfi_|\.loc\b|\.file\b|\.section\b|\.build_version\b|\.subsections_via_symbols\b|\.p2align\b|\.no_dead_strip\b|\.type\b|\.size\b|\.addrsig\b|\.ident\b|\.note\b|# resolved_symbol:|Ltmp[0-9]+:|Lfunc_begin[0-9]+:|Lfunc_end[0-9]+:)'
    $lines
    | where { |line| not ($line =~ $skip_pattern) }
    | each { |line|
        $line
        | str replace -r '^\s*[0-9A-Fa-f]+:\s+' ''
        | str replace -r '\s+$' ''
    }
    | where { |line| $line != "" }
}

def trim-asm-symbol-lines [lines: list<string>] {
    let debug_markers = ($lines | enumerate | where item =~ '^(Lsection_debug_|\.section\s+(__DWARF|\.debug_))')
    if ($debug_markers | length) == 0 {
        $lines
    } else {
        $lines | first ($debug_markers | get 0.index)
    }
}

def extract-asm-symbol-slices [asm_file: string, raw_symbol_dir: string, normalized_symbol_dir: string] {
    let lines = (open --raw $asm_file | lines)
    let total = ($lines | length)
    let asm_name = (($asm_file | path basename) | str replace ".s" "")

    let symbols = (
        $ASM_SYMBOLS
        | each { |symbol|
            let matches = ($lines | enumerate | where item =~ $"^_?($symbol):$")
            if ($matches | length) == 0 {
                null
            } else {
                {
                    symbol: $symbol
                    start: ($matches | get 0.index)
                }
            }
        }
        | where { |entry| $entry != null }
        | sort-by start
    )

    if ($symbols | length) == 0 {
        return []
    }

    mut extracted = []
    for index in 0..(($symbols | length) - 1) {
        let entry = ($symbols | get $index)
        let next_start = if $index + 1 < ($symbols | length) {
            ($symbols | get ($index + 1) | get start)
        } else {
            $total
        }
        let slice_len = $next_start - ($entry | get start)
        let raw_lines = ($lines | skip ($entry | get start) | first $slice_len)
        let raw_lines = (trim-asm-symbol-lines $raw_lines)
        let normalized_lines = (normalize-asm-lines $raw_lines)
        let key = $"($asm_name)--(($entry | get symbol)).s"
        let raw_file = [$raw_symbol_dir $key] | path join
        let normalized_file = [$normalized_symbol_dir $key] | path join
        ($raw_lines | str join "\n") | save -f $raw_file
        ($normalized_lines | str join "\n") | save -f $normalized_file
        $extracted = ($extracted | append [{
            key: $key
            symbol: ($entry | get symbol)
            asm_file: ($asm_file | path basename)
            raw_file: $raw_file
            normalized_file: $normalized_file
        }])
    }

    $extracted
}

def summarize-asm-artifacts [name: string, out_dir: string, build_exit_code: int, build_log: string] {
    let raw_dir = (asm-raw-dir $out_dir $name)
    let raw_symbol_dir = (asm-symbol-dir $out_dir $name "raw")
    let normalized_symbol_dir = (asm-symbol-dir $out_dir $name "normalized")
    let summary_file = [(asm-artifact-dir $out_dir $name) "summary.json"] | path join

    let asm_files = if ($raw_dir | path exists) {
        ls $raw_dir | get name | each { path basename } | sort
    } else {
        []
    }

    mut extracted = []
    if $build_exit_code == 0 and ($raw_dir | path exists) {
        for asm_file in ($asm_files | where { $in =~ '\.s$' } | each { [$raw_dir $in] | path join }) {
            $extracted = ($extracted | append (extract-asm-symbol-slices $asm_file $raw_symbol_dir $normalized_symbol_dir))
        }
    }

    let summary = {
        version: 1
        collected_at: (iso-timestamp)
        target: $name
        build_exit_code: $build_exit_code
        build_log: $build_log
        raw_dir: $raw_dir
        raw_symbol_dir: $raw_symbol_dir
        normalized_symbol_dir: $normalized_symbol_dir
        asm_files: $asm_files
        symbol_files: ($extracted | get key | sort)
    }
    $summary | to json --indent 2 | save -f $summary_file
    $summary
}

def find-symbol-file [dir: string, symbol: string] {
    if not ($dir | path exists) {
        return null
    }
    let matches = (
        ls $dir
        | get name
        | where { |path| (($path | path basename) | str ends-with $"--($symbol).s") }
        | sort
    )
    if ($matches | length) == 0 { null } else { $matches | first }
}

def read-resolved-symbol [raw_file: string] {
    if $raw_file == null or not ($raw_file | path exists) {
        return null
    }
    let matches = (
        open --raw $raw_file
        | lines
        | where { |line| $line =~ '^# resolved_symbol:\s*' }
    )
    if ($matches | length) == 0 {
        null
    } else {
        ($matches | first | str replace -r '^# resolved_symbol:\s*' '')
    }
}

def asm-mnemonics [normalized_file: string] {
    if $normalized_file == null or not ($normalized_file | path exists) {
        return []
    }
    open --raw $normalized_file
    | lines
    | each { str trim }
    | where { |line| $line != "" and not ($line | str ends-with ":") and not ($line =~ '^#') }
    | each { |line| ($line | split row --regex '\s+' | get 0) }
}

def histogram [values: list<string>] {
    $values | reduce -f {} { |value, acc|
        let count = (($acc | get -o $value) | default 0)
        $acc | upsert $value ($count + 1)
    }
}

def summarize-asm-pair [normalized_dir: string, raw_dir: string, label: string, left_symbol: string, right_symbol: string] {
    let left_file = (find-symbol-file $normalized_dir $left_symbol)
    let right_file = (find-symbol-file $normalized_dir $right_symbol)
    let left_raw = (find-symbol-file $raw_dir $left_symbol)
    let right_raw = (find-symbol-file $raw_dir $right_symbol)

    if $left_file == null or $right_file == null {
        return {
            label: $label
            left_symbol: $left_symbol
            right_symbol: $right_symbol
            available: false
            left_file: $left_file
            right_file: $right_file
        }
    }

    let left_mnemonics = (asm-mnemonics $left_file)
    let right_mnemonics = (asm-mnemonics $right_file)
    let left_hist = (histogram $left_mnemonics)
    let right_hist = (histogram $right_mnemonics)
    let mnemonics = (($left_hist | columns) | append ($right_hist | columns) | uniq | sort)
    let mnemonic_deltas = (
        $mnemonics
        | each { |mnemonic|
            let left_count = (($left_hist | get -o $mnemonic) | default 0)
            let right_count = (($right_hist | get -o $mnemonic) | default 0)
            {
                mnemonic: $mnemonic
                left: $left_count
                right: $right_count
                delta: ($left_count - $right_count)
            }
        }
        | where { |row| ($row.delta != 0) }
    )

    {
        label: $label
        left_symbol: $left_symbol
        right_symbol: $right_symbol
        available: true
        left_file: $left_file
        right_file: $right_file
        left_raw_file: $left_raw
        right_raw_file: $right_raw
        left_resolved_symbol: (read-resolved-symbol $left_raw)
        right_resolved_symbol: (read-resolved-symbol $right_raw)
        left_instruction_count: ($left_mnemonics | length)
        right_instruction_count: ($right_mnemonics | length)
        instruction_delta: (($left_mnemonics | length) - ($right_mnemonics | length))
        mnemonic_deltas: $mnemonic_deltas
    }
}

def write-asm-comparison-summary [name: string, out_dir: string] {
    let asm_dir = (asm-artifact-dir $out_dir $name)
    let raw_symbol_dir = (asm-symbol-dir $out_dir $name "raw")
    let normalized_symbol_dir = (asm-symbol-dir $out_dir $name "normalized")
    let summary_file = [$asm_dir "compare.json"] | path join
    let comparisons = [
        (summarize-asm-pair $normalized_symbol_dir $raw_symbol_dir "copy_vs_glibc" "fastmem_copy" "glibc_memcpy")
        (summarize-asm-pair $normalized_symbol_dir $raw_symbol_dir "move_vs_glibc" "fastmem_move" "glibc_memmove")
    ]
    let summary = {
        version: 1
        collected_at: (iso-timestamp)
        target: $name
        file: $summary_file
        comparisons: $comparisons
    }
    $summary | to json --indent 2 | save -f $summary_file
    $summary
}

def abs-int [value: int] {
    if $value < 0 { 0 - $value } else { $value }
}

def top-mnemonic-deltas [deltas: list<record>, limit: int = 8] {
    if ($deltas | length) == 0 {
        []
    } else {
        $deltas
        | each { |row| $row | insert abs_delta (abs-int ($row | get delta)) }
        | sort-by abs_delta --reverse
        | first $limit
        | each { reject abs_delta }
    }
}

def asm-signal-list [raw_file: string, resolved_symbol: string = ""] {
    if $raw_file == null or not ($raw_file | path exists) {
        return []
    }

    let raw = (open --raw $raw_file)
    mut signals = []

    if $resolved_symbol != "" {
        $signals = ($signals | append [$resolved_symbol])
    }
    if ($raw | str contains "%zmm") or ($raw | str contains "zmm") {
        $signals = ($signals | append ["avx512-zmm"])
    }
    if ($raw | str contains "%ymm") or ($raw | str contains "ymm") {
        $signals = ($signals | append ["avx2-ymm"])
    }
    if ($raw | str contains "%xmm") or ($raw | str contains "xmm") {
        $signals = ($signals | append ["xmm-tier"])
    }
    if ($raw | str contains "rep movsb") {
        $signals = ($signals | append ["rep-movsb"])
    }
    if ($raw | str contains "__x86_rep_movsb_threshold") or ($raw | str contains "__x86_shared_non_temporal_threshold") {
        $signals = ($signals | append ["threshold-gates"])
    }
    if ($raw | str contains "vmovdqa64") {
        $signals = ($signals | append ["aligned-vector-stores"])
    }
    if ($raw | str contains "ldp") and ($raw | str contains "stp") {
        $signals = ($signals | append ["paired-load-store"])
    }
    if ($raw | str contains "ptrue") or ($resolved_symbol | str contains "_sve") {
        $signals = ($signals | append ["sve"])
    }

    $signals | uniq
}

def format-int-delta [value: int] {
    if $value > 0 {
        $"+($value)"
    } else if $value < 0 {
        $"($value)"
    } else {
        "0"
    }
}

def write-asm-reference-doc [name: string, out_dir: string, host_summary: record, compare_summary: record] {
    let asm_dir = (asm-artifact-dir $out_dir $name)
    let reference_file = [$asm_dir "reference.md"] | path join
    let baseline_file = (asm-baseline-file $name)
    let asm_summary_file = [$asm_dir "summary.json"] | path join
    let facts = ($host_summary | get facts)

    mkdir (asm-baseline-dir)

    mut lines = [
        $"# ASM Reference: ($name)"
        ""
        $"Generated: ($compare_summary.collected_at)"
        $"Host: (($facts | get -o cpu_summary) | default "unknown")"
        $"OS: ((($facts | get -o os_name) | default "unknown")) ((($facts | get -o os_version) | default ""))"
        $"Kernel: (($facts | get -o uname_r) | default "unknown")"
        $"Toolchain: zig ((($facts | get -o zig_version) | default "unknown"))"
        ""
        "This file captures the latest host-local asm reference outside the benchmark output."
        ""
        "## Source Files"
        ""
        $"- asm summary: `($asm_summary_file)`"
        $"- asm comparison summary: `($compare_summary.file)`"
        ""
    ]

    for comparison in ($compare_summary | get comparisons) {
        let left_symbol = ($comparison | get left_symbol)
        let right_symbol = ($comparison | get right_symbol)
        let left_resolved = (($comparison | get -o left_resolved_symbol) | default $left_symbol)
        let right_resolved = (($comparison | get -o right_resolved_symbol) | default $right_symbol)
        let left_raw_file = (($comparison | get -o left_raw_file) | default "")
        let right_raw_file = (($comparison | get -o right_raw_file) | default "")
        let left_signals = (asm-signal-list $left_raw_file $left_resolved)
        let right_signals = (asm-signal-list $right_raw_file $right_resolved)
        let left_signal_text = if ($left_signals | length) == 0 { "none" } else { $left_signals | str join "`, `" }
        let right_signal_text = if ($right_signals | length) == 0 { "none" } else { $right_signals | str join "`, `" }
        let top_deltas = (top-mnemonic-deltas ($comparison | get -o mnemonic_deltas | default []))

        $lines = ($lines | append [
            $"## ($comparison.label)"
            ""
        ])

        if not (($comparison | get -o available) | default false) {
            $lines = ($lines | append [
                "Assembly pair unavailable for this target."
                ""
            ])
            continue
        }

        $lines = ($lines | append [
            $"- fastmem symbol: `($left_symbol)`"
            $"- fastmem raw: `($left_raw_file)`"
            $"- fastmem normalized: `(($comparison | get left_file))`"
            $"- fastmem signals: `($left_signal_text)`"
            $"- glibc symbol: `($right_resolved)`"
            $"- glibc raw: `($right_raw_file)`"
            $"- glibc normalized: `(($comparison | get right_file))`"
            $"- glibc signals: `($right_signal_text)`"
            $"- instruction counts: fastmem `(($comparison | get left_instruction_count))`, glibc `(($comparison | get right_instruction_count))`, delta `((format-int-delta ($comparison | get instruction_delta)))`"
            "- top mnemonic deltas:"
        ])

        if ($top_deltas | length) == 0 {
            $lines = ($lines | append ["  - none"])
        } else {
            for delta in $top_deltas {
                $lines = ($lines | append [
                    $"  - `(($delta | get mnemonic))` ((format-int-delta ($delta | get delta)))"
                ])
            }
        }

        $lines = ($lines | append [""])
    }

    let doc = ($lines | str join "\n")
    $doc | save -f $reference_file
    $doc | save -f $baseline_file

    {
        reference_file: $reference_file
        baseline_file: $baseline_file
    }
}

def collect-local-asm-artifacts [name: string, out_dir: string, source_dir: string, host_summary: record] {
    let asm_dir = (asm-artifact-dir $out_dir $name)
    let raw_dir = (asm-raw-dir $out_dir $name)
    let raw_symbol_dir = (asm-symbol-dir $out_dir $name "raw")
    let normalized_symbol_dir = (asm-symbol-dir $out_dir $name "normalized")
    mkdir $asm_dir
    mkdir $raw_dir
    mkdir $raw_symbol_dir
    mkdir $normalized_symbol_dir

    let build_log = [$asm_dir "build.txt"] | path join
    let marker_result = (do { ^mktemp -t "fastmem-asm-marker.XXXXXX" } | complete)
    let marker_file = ($marker_result.stdout | str trim)

    let build_out = (do { cd $source_dir; ^zig build asm } | complete)
    ($build_out.stdout + $build_out.stderr) | save -f $build_log

    if $build_out.exit_code == 0 and $marker_file != "" {
        let native_basename = (native-asm-basename-from-facts ($host_summary | get facts))
        let files = (list-newer-files $"($source_dir)/zig-out/asm" $marker_file)
        let files = if ($files | length) == 0 {
            fallback-local-asm-files $source_dir $native_basename
        } else {
            $files
        }

        for file in $files {
            ^cp $file $"($raw_dir)/(($file | path basename))"
        }
    } else if $build_out.exit_code != 0 {
        print $"warning: [($name)] failed to collect asm; see ($build_log)"
    }

    let asm_summary = (summarize-asm-artifacts $name $out_dir $build_out.exit_code $build_log)
    let compare_summary = (write-asm-comparison-summary $name $out_dir)
    let reference_files = (write-asm-reference-doc $name $out_dir $host_summary $compare_summary)
    $asm_summary | merge {
        compare_file: ($compare_summary | get file)
        reference_file: ($reference_files | get reference_file)
        baseline_file: ($reference_files | get baseline_file)
    }
}

def collect-remote-asm-artifacts [name: string, out_dir: string, t: record, ssh_cmd: string, host_summary: record] {
    let asm_dir = (asm-artifact-dir $out_dir $name)
    let raw_dir = (asm-raw-dir $out_dir $name)
    let raw_symbol_dir = (asm-symbol-dir $out_dir $name "raw")
    let normalized_symbol_dir = (asm-symbol-dir $out_dir $name "normalized")
    mkdir $asm_dir
    mkdir $raw_dir
    mkdir $raw_symbol_dir
    mkdir $normalized_symbol_dir

    # The benchmark outputs are already fetched before asm capture begins, so
    # it is safe to reclaim remote disk here before building asm artifacts.
    ensure-remote-free-space $name $t

    let build_log = [$asm_dir "build.txt"] | path join
    let remote_build_log = $"($t.remote_dir)/bench-results/asm-build.txt"
    let marker_out = (do {
        ^ssh ...$t.ssh_opts $t.ssh_dest $"mktemp -t fastmem-asm-marker.XXXXXX"
    } | complete)
    let marker_file = ($marker_out.stdout | str trim)

    let build_out = if $marker_file != "" {
        do {
            ^ssh ...$t.ssh_opts $t.ssh_dest $"cd ($t.remote_dir) && nix develop --command just asm > bench-results/asm-build.txt 2>&1"
        } | complete
    } else {
        { exit_code: 1 stdout: "" stderr: "failed to create remote asm marker file" }
    }
    fetch-remote-log $ssh_cmd $t.ssh_dest $remote_build_log $build_log
    if not ($build_log | path exists) {
        ($build_out.stdout + $build_out.stderr) | save -f $build_log
    }

    if $build_out.exit_code == 0 and $marker_file != "" {
        let native_basename = (native-asm-basename-from-facts ($host_summary | get facts))
        let remote_files_out = (do {
            ^ssh ...$t.ssh_opts $t.ssh_dest $"find ($t.remote_dir)/zig-out/asm -maxdepth 1 -type f -newer ($marker_file)"
        } | complete)
        let remote_files = if $remote_files_out.exit_code == 0 {
            $remote_files_out.stdout | lines | each { str trim } | where { $in != "" } | sort
        } else {
            []
        }
        let remote_files = if ($remote_files | length) == 0 {
            fallback-remote-asm-files $t.remote_dir $native_basename
        } else {
            $remote_files
        }

        for remote_file in $remote_files {
            ^rsync -az -e $ssh_cmd $"($t.ssh_dest):($remote_file)" $"($raw_dir)/(($remote_file | path basename))"
        }

        if (supports-glibc-disassembly ($host_summary | get facts)) {
            # glibc probing and disassembly can be the last step on long-lived
            # hosts, so do one more free-space check before writing extra files.
            ensure-remote-free-space $name $t

            let remote_results = $"($t.remote_dir)/bench-results"
            let remote_probe_log = $"($remote_results)/libc-probe-build.txt"
            let local_probe_log = [$asm_dir "glibc-probe-build.txt"] | path join
            let remote_probe_json = $"($remote_results)/libc-probe.json"
            let local_probe_json = [$asm_dir "glibc-probe.json"] | path join
            let remote_probe_cmd = $"cd ($t.remote_dir) && mkdir -p bench-results && nix develop --command sh -lc 'zig build libc-probe > bench-results/libc-probe-build.txt 2>&1 && ./zig-out/bin/libc-probe > bench-results/libc-probe.json'"
            let probe_out = (do { ^ssh ...$t.ssh_opts $t.ssh_dest $remote_probe_cmd } | complete)
            fetch-remote-log $ssh_cmd $t.ssh_dest $remote_probe_log $local_probe_log

            if $probe_out.exit_code == 0 {
                let probe_fetch = (do { ^rsync -az -e $ssh_cmd $"($t.ssh_dest):($remote_probe_json)" $local_probe_json } | complete)
                if $probe_fetch.exit_code != 0 {
                    print $"warning: [($name)] failed to fetch glibc probe output\n($probe_fetch.stderr)"
                } else {
                    let probe = (open $local_probe_json)
                    for entry in ($probe | get -o functions | default []) {
                        let label = $"glibc_($entry.name)"
                        let raw_name = $"glibc-($entry.name).s"
                        let remote_raw = $"($remote_results)/($raw_name)"
                        let local_raw = [$raw_dir $raw_name] | path join
                        let symbol_name = (($entry | get -o symbol_name) | default "")
                        let start_addr = (($entry.addr | into int) - (($entry | get -o library_base | default 0) | into int))
                        let stop_addr = $start_addr + $GLIBC_DISASM_WINDOW_BYTES
                        let dump_cmd = $"cd ($t.remote_dir) && nix develop --command ./infra/dump-glibc-symbol.sh (sh-quote $label) (sh-quote ($entry.library_path | into string)) (sh-quote $symbol_name) (sh-quote $"($start_addr)") (sh-quote $"($stop_addr)") (sh-quote $remote_raw)"
                        let dump_out = (do { ^ssh ...$t.ssh_opts $t.ssh_dest $dump_cmd } | complete)
                        if $dump_out.exit_code != 0 {
                            print $"warning: [($name)] failed to capture glibc symbol ($entry.name)\n($dump_out.stderr)"
                            continue
                        }
                        let raw_fetch = (do { ^rsync -az -e $ssh_cmd $"($t.ssh_dest):($remote_raw)" $local_raw } | complete)
                        if $raw_fetch.exit_code != 0 {
                            print $"warning: [($name)] failed to fetch glibc asm ($remote_raw)\n($raw_fetch.stderr)"
                        } else {
                            do { ^ssh ...$t.ssh_opts $t.ssh_dest $"rm -f ($remote_raw) ($remote_probe_json)" } | complete | ignore
                        }
                    }
                }
            } else {
                let probe_log = if ($local_probe_log | path exists) { open --raw $local_probe_log } else { "" }
                if not ($probe_log | str contains "no step named 'libc-probe'") {
                    print $"warning: [($name)] failed to build or run libc probe; see ($local_probe_log)"
                }
            }
        }
    } else {
        print $"warning: [($name)] failed to collect asm; see ($build_log)"
    }

    let asm_summary = (summarize-asm-artifacts $name $out_dir $build_out.exit_code $build_log)
    let compare_summary = (write-asm-comparison-summary $name $out_dir)
    let reference_files = (write-asm-reference-doc $name $out_dir $host_summary $compare_summary)
    $asm_summary | merge {
        compare_file: ($compare_summary | get file)
        reference_file: ($reference_files | get reference_file)
        baseline_file: ($reference_files | get baseline_file)
    }
}

def write-target-artifact-summary [name: string, out_dir: string, host_summary: record, asm_summary: record] {
    let summary_file = [(artifact-dir $out_dir $name) "summary.json"] | path join
    let summary = {
        version: 1
        collected_at: (iso-timestamp)
        target: $name
        host: $host_summary
        asm: $asm_summary
    }
    $summary | to json --indent 2 | save -f $summary_file
    $summary
}

def build-worktree-source-meta [] {
    let status_lines = (git-status-lines)
    {
        kind: "worktree"
        repo_dir: (project-dir)
        git_ref: "HEAD"
        git_commit: (git-current-head)
        git_branch: (git-branch)
        git_describe: (git-describe)
        git_subject: (git-subject)
        dirty: (($status_lines | length) > 0)
        status: $status_lines
    }
}

def build-git-ref-source-meta [ref: string] {
    let resolved = (git-rev-parse $ref)
    {
        kind: "git-ref"
        repo_dir: (project-dir)
        git_ref: $ref
        git_commit: $resolved
        git_branch: ""
        git_describe: (git-describe $ref)
        git_subject: (git-subject $ref)
        dirty: false
        status: []
    }
}

def write-run-metadata [out_dir: string, meta: record] {
    $meta | to json --indent 2 | save -f ([$out_dir "meta.json"] | path join)
}

def materialize-git-ref [ref: string] {
    let temp_dir_result = (do { ^mktemp -d -t "fastmem-bench.XXXXXX" } | complete)
    if $temp_dir_result.exit_code != 0 {
        error make { msg: $"Failed to create temp directory for git ref '($ref)'.\n($temp_dir_result.stderr)" }
    }
    let temp_dir = ($temp_dir_result.stdout | str trim)
    let archive_result = (do {
        ^sh -lc $"cd '((project-dir))' && git archive --format=tar '($ref)' | tar -xf - -C '($temp_dir)'"
    } | complete)
    if $archive_result.exit_code != 0 {
        error make { msg: $"Failed to materialize git ref '($ref)' into ($temp_dir).\n($archive_result.stderr)" }
    }
    $temp_dir
}

def maybe-cleanup-temp-dir [dir: string] {
    if $dir == "" {
        return
    }
    if not ($dir | path exists) {
        return
    }
    if ("fastmem-bench." not-in $dir) {
        error make { msg: $"Refusing to remove unexpected temp dir: ($dir)" }
    }
    ^rm -rf $dir
}

# ── Target resolution ──────────────────────────────────────────────

def all-target-names [] {
    ["local"] | append $ORB_INSTANCE_NAMES | append $AWS_INSTANCE_NAMES
}

def resolve-run-targets [name: string] {
    if $name == "all" { all-target-names } else { [$name] }
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
        let instances = (tofu-output-optional "instances")
        let fallback_ssh_dest = ($AWS_INSTANCE_FALLBACK_SSH_DESTS | get -o $name)
        let ssh_dest = if $instances != null {
            let inst = ($instances | get -o $name)
            let ip = if $inst == null { "" } else { ($inst | get -o public_ip | default "") }
            if $ip == "" {
                if $fallback_ssh_dest == null {
                    error make { msg: $"Instance ($name) not found in tofu output and no fallback ssh destination is recorded." }
                }
                print $"warning: [($name)] tofu output is missing a public IP; falling back to cached ssh destination ($fallback_ssh_dest)"
                $fallback_ssh_dest
            } else {
                $"root@($ip)"
            }
        } else {
            if $fallback_ssh_dest == null {
                error make { msg: $"Failed to read tofu output 'instances' and no fallback ssh destination is recorded for ($name)." }
            }
            print $"warning: [($name)] tofu output is unavailable; falling back to cached ssh destination ($fallback_ssh_dest)"
            $fallback_ssh_dest
        }

        return {
            ssh_dest: $ssh_dest
            remote_dir: "/root/fastmem-zig"
            ssh_opts: [...$SSH_OPTS "-i" (ssh-key-file)]
        }
    }

    error make { msg: $"Unknown target: ($name)" }
}

def target-sync [name: string, source_dir: string = ""] {
    let t = (resolve-target $name)
    let local_dir = if $source_dir == "" { project-dir } else { $source_dir }
    print $"[($name)] Syncing to ($t.ssh_dest):($t.remote_dir)..."
    let ssh_cmd = if ($t.ssh_opts | length) > 0 {
        ["ssh" ...$t.ssh_opts] | str join " "
    } else {
        "ssh"
    }
    let result = (rsync-complete-with-retries $"[($name)] rsync source tree" [
        "-az"
        ...(rsync-excludes)
        "-e" $ssh_cmd
        $"($local_dir)/"
        $"($t.ssh_dest):($t.remote_dir)/"
    ])
    if $result.exit_code != 0 {
        error make { msg: $"[($name)] rsync failed.
($result.stderr)" }
    }
    print $"[($name)] Done."
}

def fetch-remote-log [ssh_cmd: string, ssh_dest: string, remote_file: string, local_file: string] {
    let result = (rsync-complete-with-retries $"fetch log ($remote_file)" [
        "-az"
        "-e" $ssh_cmd
        $"($ssh_dest):($remote_file)"
        $local_file
    ])
    if $result.exit_code != 0 {
        print $"warning: failed to fetch log ($remote_file) -> ($local_file)
($result.stderr)"
    }
}

def target-bench [name: string, out_dir: string, source_dir: string] {
    let logs_dir = ([$out_dir "logs"] | path join)
    mkdir $logs_dir

    if $name == "local" {
        local-bench $out_dir $source_dir
        return
    }

    let t = (resolve-target $name)

    print $"=== [($name)] Checking remote disk ==="
    ensure-remote-free-space $name $t

    print $"=== [($name)] Syncing ==="
    target-sync $name $source_dir

    let remote_results = $"($t.remote_dir)/bench-results"
    let ssh_cmd = if ($t.ssh_opts | length) > 0 {
        ["ssh" ...$t.ssh_opts] | str join " "
    } else {
        "ssh"
    }
    let remote_test = $"($remote_results)/test.txt"
    let local_test = $"($logs_dir)/($name)-test.txt"

    print $"=== [($name)] Running tests ==="
    let test_out = (ssh-complete-with-retries $"[($name)] remote tests" $t $"cd ($t.remote_dir) && mkdir -p bench-results && nix develop --command just test > bench-results/test.txt 2>&1")
    fetch-remote-log $ssh_cmd $t.ssh_dest $remote_test $local_test
    if $test_out.exit_code != 0 {
        error make { msg: $"[($name)] Tests failed, see ($local_test)" }
    }

    print $"=== [($name)] Capturing host info ==="
    let host_summary = (collect-remote-host-artifacts $name $out_dir $t)

    print $"=== [($name)] Running bench ==="
    let bench_out = (ssh-complete-with-retries $"[($name)] remote bench" $t $"cd ($t.remote_dir) && mkdir -p bench-results && nix develop --command just bench > bench-results/bench.txt 2>&1")
    if $bench_out.exit_code != 0 {
        error make { msg: $"[($name)] Benchmark run failed, see ($remote_results)/bench.txt on target" }
    }

    print $"=== [($name)] Running bench-libc ==="
    let libc_out = (ssh-complete-with-retries $"[($name)] remote bench-libc" $t $"cd ($t.remote_dir) && nix develop --command just bench-libc > bench-results/bench-libc.txt 2>&1")
    if $libc_out.exit_code != 0 {
        error make { msg: $"[($name)] libc benchmark run failed, see ($remote_results)/bench-libc.txt on target" }
    }

    print $"=== [($name)] Fetching results ==="
    let bench_fetch = (rsync-complete-with-retries $"[($name)] fetch bench results" [
        "-az"
        "-e" $ssh_cmd
        $"($t.ssh_dest):($remote_results)/bench.txt"
        $"($out_dir)/($TAG_PREFIX)-($name).txt"
    ])
    if $bench_fetch.exit_code != 0 {
        error make { msg: $"[($name)] failed to fetch bench results.
($bench_fetch.stderr)" }
    }
    let bench_libc_fetch = (rsync-complete-with-retries $"[($name)] fetch bench-libc results" [
        "-az"
        "-e" $ssh_cmd
        $"($t.ssh_dest):($remote_results)/bench-libc.txt"
        $"($out_dir)/($TAG_PREFIX)-($name)-libc.txt"
    ])
    if $bench_libc_fetch.exit_code != 0 {
        error make { msg: $"[($name)] failed to fetch bench-libc results.
($bench_libc_fetch.stderr)" }
    }

    print $"=== [($name)] Capturing native asm ==="
    let asm_summary = (collect-remote-asm-artifacts $name $out_dir $t $ssh_cmd $host_summary)
    write-target-artifact-summary $name $out_dir $host_summary $asm_summary | ignore

    print $"=== [($name)] Complete ==="
}

def local-bench [out_dir: string, source_dir: string] {
    let logs_dir = ([$out_dir "logs"] | path join)
    mkdir $logs_dir

    print "=== [local] Running tests ==="
    let test_out = (do { cd $source_dir; ^zig build test } | complete)
    print $test_out.stdout
    if $test_out.stderr != "" { print $test_out.stderr }
    ($test_out.stdout + $test_out.stderr) | save -f $"($logs_dir)/local-test.txt"
    if $test_out.exit_code != 0 {
        error make { msg: "[local] Tests failed, skipping benchmarks" }
    }

    print "=== [local] Capturing host info ==="
    let host_summary = (collect-local-host-artifacts "local" $out_dir $source_dir)

    print "=== [local] Running bench ==="
    let bench_out = (do { cd $source_dir; ^zig build bench -- } | complete)
    print $bench_out.stdout
    if $bench_out.stderr != "" { print $bench_out.stderr }
    ($bench_out.stdout + $bench_out.stderr) | save -f $"($out_dir)/($TAG_PREFIX)-local.txt"

    print "=== [local] Running bench-libc ==="
    let libc_out = (do { cd $source_dir; ^zig build bench -Dlink-libc=true -- } | complete)
    print $libc_out.stdout
    if $libc_out.stderr != "" { print $libc_out.stderr }
    ($libc_out.stdout + $libc_out.stderr) | save -f $"($out_dir)/($TAG_PREFIX)-local-libc.txt"

    print "=== [local] Capturing native asm ==="
    let asm_summary = (collect-local-asm-artifacts "local" $out_dir $source_dir $host_summary)
    write-target-artifact-summary "local" $out_dir $host_summary $asm_summary | ignore

    print "=== [local] Complete ==="
}

def run-bench-suite [targets: list<string>, source_dir: string, out_dir: string, source_meta: record, run_kind: string, run_label: string = ""] {
    mkdir $out_dir
    let meta = {
        version: 1
        kind: $run_kind
        created_at: (iso-timestamp)
        output_dir: $out_dir
        label: $run_label
        targets: $targets
        runner: {
            hostname: (runner-hostname)
            script: "infra/bench.nu"
        }
        source: $source_meta
    }
    write-run-metadata $out_dir $meta
    $targets | par-each { |n| target-bench $n $out_dir $source_dir }
}

def parse-benchstat-name [name: string] {
    let parts = ($name | split row "/")
    let family = (($parts | first) | str replace -r '^BenchStat' '')
    mut meta = {
        family: $family
        name: $name
    }

    for part in ($parts | skip 1) {
        let kv = ($part | split row "=")
        if ($kv | length) == 2 {
            $meta = ($meta | upsert ($kv | get 0) ($kv | get 1))
        }
    }

    let size_label = (($meta | get -o size) | default "")
    let gap_label = (($meta | get -o gap) | default "")
    $meta | merge {
        profile: (($meta | get -o profile) | default "")
        dir: (($meta | get -o dir) | default "")
        size_label: $size_label
        size_bytes: (if $size_label == "" { null } else { ($size_label | str replace "B" "" | into int) })
        gap_value: (if $gap_label == "" { null } else { $gap_label | into int })
        impl: (($meta | get -o impl) | default "")
    }
}

def parse-benchstat-file [file: string] {
    if not ($file | path exists) {
        return []
    }

    open --raw $file
    | lines
    | where { |line| $line | str starts-with "BenchStat" }
    | each { |line|
        let parsed = ($line | parse -r '^(?<name>[^\t]+)\tsamples=(?<samples>\d+)\tns/op p50=(?<ns_p50>[0-9.]+) p95=(?<ns_p95>[0-9.]+)\tGiB/s p50=(?<gib_p50>[0-9.]+) p95=(?<gib_p95>[0-9.]+)(?:\tdelta_vs_builtin_p50=(?<delta>[^\t]+))?$')
        if ($parsed | length) == 0 {
            null
        } else {
            let row = ($parsed | first)
            let meta = (parse-benchstat-name ($row | get name))
            $meta | merge {
                file: $file
                samples: (($row | get samples) | into int)
                ns_p50: (($row | get ns_p50) | into float)
                ns_p95: (($row | get ns_p95) | into float)
                gib_p50: (($row | get gib_p50) | into float)
                gib_p95: (($row | get gib_p95) | into float)
            }
        }
    }
    | where { |row| $row != null }
}

def geomean [values: list<any>] {
    if ($values | length) == 0 {
        null
    } else {
        let avg = ($values | each { |value| ($value | into float | math ln) } | math avg)
        $avg | math exp
    }
}

def pct-delta [value: any, baseline: any] {
    if $value == null or $baseline == null {
        null
    } else if ($baseline | into float) == 0.0 {
        null
    } else {
        ((($value | into float) - ($baseline | into float)) / ($baseline | into float)) * 100.0
    }
}

def format-float [value: any, precision: int = 2] {
    if $value == null {
        ""
    } else {
        (($value | into float | math round --precision $precision) | into string)
    }
}

def format-ns [value: any] {
    if $value == null { "" } else { $"((format-float $value 2))n" }
}

def format-gib [value: any] {
    if $value == null { "" } else { $"((format-float $value 2))GiB" }
}

def format-pct [value: any] {
    if $value == null {
        ""
    } else {
        let rounded = (($value | into float) | math round --precision 2)
        if $rounded > 0 {
            $"+(($rounded | into string))%"
        } else {
            $"(($rounded | into string))%"
        }
    }
}

def bench-categories [rows: list<record>] {
    let move_gaps = (
        $rows
        | where { |row| $row.family == "Move" and $row.gap_value != null }
        | get gap_value
        | uniq
        | sort
    )

    [
        { label: "copy/all", family: "Copy" }
        { label: "copy/aligned", family: "Copy", profile: "aligned" }
        { label: "copy/misaligned", family: "Copy", profile: "misaligned" }
        { label: "copy/cross-lane", family: "Copy", profile: "cross-lane" }
        { label: "move/fwd/all", family: "Move", dir: "fwd" }
    ]
    | append ($move_gaps | each { |gap|
        {
            label: $"move/fwd/gap=($gap)"
            family: "Move"
            dir: "fwd"
            gap_value: $gap
        }
    })
    | append [{ label: "move/bwd/all", family: "Move", dir: "bwd" }]
    | append ($move_gaps | each { |gap|
        {
            label: $"move/bwd/gap=($gap)"
            family: "Move"
            dir: "bwd"
            gap_value: $gap
        }
    })
}

def rows-for-category [rows: list<record>, category: record] {
    mut filtered = ($rows | where { |row| $row.family == ($category | get family) })

    let profile = (($category | get -o profile) | default "")
    if $profile != "" {
        $filtered = ($filtered | where { |row| $row.profile == $profile })
    }

    let dir = (($category | get -o dir) | default "")
    if $dir != "" {
        $filtered = ($filtered | where { |row| $row.dir == $dir })
    }

    let gap_value = (($category | get -o gap_value) | default null)
    if $gap_value != null {
        $filtered = ($filtered | where { |row| $row.gap_value == $gap_value })
    }

    let size_bytes = (($category | get -o size_bytes) | default null)
    if $size_bytes != null {
        $filtered = ($filtered | where { |row| $row.size_bytes == $size_bytes })
    }

    $filtered
}

def bench-category-size-groups [rows: list<record>] {
    mut groups = []
    for category in (bench-categories $rows) {
        let category_rows = (rows-for-category $rows $category)
        if ($category_rows | length) == 0 {
            continue
        }

        let sizes = (
            $category_rows
            | where { |row| $row.size_bytes != null }
            | get size_bytes
            | uniq
            | sort
        )
        for size in $sizes {
            let size_label = (
                $category_rows
                | where { |row| $row.size_bytes == $size }
                | get size_label
                | uniq
                | sort
                | first
            )
            $groups = ($groups | append [($category | merge {
                label: $"(($category | get label))/($size_label)"
                size_bytes: $size
            })])
        }
    }
    $groups
}

def summarize-geomeans [rows: list<record>, groups: list<record>] {
    let impls = (
        ["builtin" "fastmem" "libc"]
        | where { |impl| (($rows | where { |row| $row.impl == $impl }) | length) > 0 }
    )

    mut ns_rows = []
    mut gib_rows = []
    for group in $groups {
        let group_rows = (rows-for-category $rows $group)
        if ($group_rows | length) == 0 {
            continue
        }

        let benchmark_count = ($group_rows | get name | uniq | length)
        let builtin_rows = ($group_rows | where { |row| $row.impl == "builtin" })
        let builtin_ns = (geomean ($builtin_rows | get ns_p50))
        let builtin_gib = (geomean ($builtin_rows | get gib_p50))

        mut ns_record = {
            category: ($group | get label)
            rows: $benchmark_count
            builtin: (format-ns $builtin_ns)
        }
        mut gib_record = {
            category: ($group | get label)
            rows: $benchmark_count
            builtin: (format-gib $builtin_gib)
        }

        for impl in ($impls | where { |impl| $impl != "builtin" }) {
            let impl_rows = ($group_rows | where { |row| $row.impl == $impl })
            if ($impl_rows | length) == 0 {
                continue
            }

            let impl_ns = (geomean ($impl_rows | get ns_p50))
            let impl_gib = (geomean ($impl_rows | get gib_p50))
            $ns_record = ($ns_record
                | upsert $impl (format-ns $impl_ns)
                | upsert $"($impl)_vs_builtin" (format-pct (pct-delta $impl_ns $builtin_ns))
            )
            $gib_record = ($gib_record
                | upsert $impl (format-gib $impl_gib)
                | upsert $"($impl)_vs_builtin" (format-pct (pct-delta $impl_gib $builtin_gib))
            )
        }

        $ns_rows = ($ns_rows | append [$ns_record])
        $gib_rows = ($gib_rows | append [$gib_record])
    }

    {
        ns_rows: $ns_rows
        gib_rows: $gib_rows
    }
}

def summarize-category-geomeans [file: string] {
    let rows = (parse-benchstat-file $file)
    if ($rows | length) == 0 {
        return {
            ns_rows: []
            gib_rows: []
        }
    }

    summarize-geomeans $rows (bench-categories $rows)
}

def summarize-size-geomeans [file: string] {
    let rows = (parse-benchstat-file $file)
    if ($rows | length) == 0 {
        return {
            ns_rows: []
            gib_rows: []
        }
    }

    summarize-geomeans $rows (bench-category-size-groups $rows)
}

def render-geomean-summary [summary: record, label: string] {
    mut sections = []

    if (($summary | get ns_rows | length) > 0) {
        let ns_table = (($summary | get ns_rows) | table --theme basic -i false -w 220)
        $sections = ($sections | append [
            $"($label) [candidate p50-derived ns/op]"
            $ns_table
            ""
        ])
    }

    if (($summary | get gib_rows | length) > 0) {
        let gib_table = (($summary | get gib_rows) | table --theme basic -i false -w 220)
        $sections = ($sections | append [
            $"($label) [candidate p50-derived GiB/s]"
            $gib_table
            ""
        ])
    }

    $sections | str join "\n"
}

def render-category-geomeans [file: string] {
    render-geomean-summary (summarize-category-geomeans $file) "Category geomeans"
}

def render-size-geomeans [file: string] {
    render-geomean-summary (summarize-size-geomeans $file) "Category-size geomeans"
}

def compare-report [base_dir: string, cand_dir: string, baseline_label: string, candidate_label: string, target: string = ""] {
    let discovered_targets = (ls $base_dir
        | where name =~ "fastmem-bench-"
        | get name
        | each { path basename }
        | each { str replace ".txt" "" | str replace "fastmem-bench-" "" | str replace "-libc" "" }
        | uniq
        | sort)

    let targets = if $target != "" {
        $discovered_targets | where { $in == $target }
    } else {
        $discovered_targets
    }

    if ($targets | length) == 0 {
        error make { msg: $"No comparable benchmark targets found in ($base_dir)" }
    }

    mut sections = [
        $"Comparing: ($baseline_label) -> ($candidate_label)"
        ""
    ]

    for t in $targets {
        for suffix in ["" "-libc"] {
            let label = if $suffix == "" { $"Target: ($t)" } else { $"Target: ($t)" + " (libc)" }
            let base_file = [$base_dir $"fastmem-bench-($t)($suffix).txt"] | path join
            let cand_file = [$cand_dir $"fastmem-bench-($t)($suffix).txt"] | path join

            if not ($base_file | path exists) or not ($cand_file | path exists) {
                continue
            }

            let impl_out = (do {
                ^benchstat -table .file -row .name,/profile,/dir,/gap,/size -col /impl $base_file $cand_file
            } | complete)
            if $impl_out.exit_code != 0 {
                error make { msg: $"benchstat failed comparing implementation columns for target ($t).\n($impl_out.stderr)" }
            }

            let delta_out = (do {
                ^benchstat -table /impl -row .name,/profile,/dir,/gap,/size -col .file $base_file $cand_file
            } | complete)
            if $delta_out.exit_code != 0 {
                error make { msg: $"benchstat failed comparing baseline vs candidate for target ($t).\n($delta_out.stderr)" }
            }

            let category_summary = (render-category-geomeans $cand_file)
            let size_summary = (render-size-geomeans $cand_file)

            $sections = ($sections | append [
                $label
                $category_summary
                $size_summary
                "Implementation comparison [builtin fastmem libc]"
                ($impl_out.stdout | str trim)
                ""
                "Baseline vs candidate per implementation"
                ($delta_out.stdout | str trim)
                ""
            ])
        }
    }

    $sections | str join "\n"
}

def generate-trial-asm-diffs [trial_dir: string, targets: list<string>] {
    let root = [$trial_dir "asm-diffs"] | path join
    mkdir $root

    mut target_summaries = []
    for target in $targets {
        let target_dir = [$root $target] | path join
        mkdir $target_dir

        let baseline_dir = [$trial_dir "baseline" "artifacts" $target "asm" "symbols" "normalized"] | path join
        let candidate_dir = [$trial_dir "candidate" "artifacts" $target "asm" "symbols" "normalized"] | path join

        let baseline_files = if ($baseline_dir | path exists) {
            ls $baseline_dir | get name | each { path basename } | sort
        } else {
            []
        }
        let candidate_files = if ($candidate_dir | path exists) {
            ls $candidate_dir | get name | each { path basename } | sort
        } else {
            []
        }

        let common_files = ($baseline_files | where { |file| $file in $candidate_files })
        mut file_summaries = []

        for file in $common_files {
            let baseline_file = [$baseline_dir $file] | path join
            let candidate_file = [$candidate_dir $file] | path join
            let diff_file = [$target_dir (($file | str replace ".s" ".diff"))] | path join
            let diff_out = (do { ^diff -u $baseline_file $candidate_file } | complete)

            if $diff_out.exit_code > 1 {
                ($diff_out.stdout + $diff_out.stderr) | save -f $diff_file
                $file_summaries = ($file_summaries | append [{
                    file: $file
                    changed: null
                    diff_file: $diff_file
                    exit_code: $diff_out.exit_code
                }])
            } else {
                let changed = ($diff_out.exit_code == 1)
                let diff_text = if $changed { $diff_out.stdout } else { "No normalized assembly differences.\n" }
                $diff_text | save -f $diff_file
                $file_summaries = ($file_summaries | append [{
                    file: $file
                    changed: $changed
                    diff_file: $diff_file
                    exit_code: $diff_out.exit_code
                }])
            }
        }

        let summary = {
            version: 1
            collected_at: (iso-timestamp)
            target: $target
            baseline_dir: $baseline_dir
            candidate_dir: $candidate_dir
            files: $file_summaries
        }
        $summary | to json --indent 2 | save -f ([$target_dir "summary.json"] | path join)
        $target_summaries = ($target_summaries | append [$summary])
    }

    $target_summaries | to json --indent 2 | save -f ([$root "summary.json"] | path join)
    $target_summaries
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
    let targets = (resolve-run-targets $name)
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
    let targets = (resolve-run-targets $name)
    let run_label = if $tag != "" { $tag } else { "ad-hoc" }
    run-bench-suite $targets (project-dir) $out_dir (build-worktree-source-meta) "bench-run" $run_label

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

    let selected_target = if $target == null { "" } else { $target }
    print (compare-report $base_dir $cand_dir $baseline $candidate $selected_target)
}

# Run a saved baseline-vs-worktree trial for a target or target set.
def "main trial" [
    name: string = "local"   # Target name or "all"
    --baseline-ref: string = "HEAD"  # Baseline git ref to materialize
    --label: string = ""     # Optional label to make the trial easier to find later
] {
    let targets = (resolve-run-targets $name)
    let trial_label = if $label == "" { $"($name)-vs-worktree" } else { $"($name)-($label)" }
    let trial_id = (make-run-id $trial_label)
    let trial_dir = [(results-dir) "trials" $trial_id] | path join
    let baseline_dir = [$trial_dir "baseline"] | path join
    let candidate_dir = [$trial_dir "candidate"] | path join
    let compare_file = [$trial_dir "comparison.txt"] | path join

    mkdir $trial_dir

    let baseline_source_meta = (build-git-ref-source-meta $baseline_ref)
    let baseline_source_dir = (materialize-git-ref $baseline_ref)
    run-bench-suite $targets $baseline_source_dir $baseline_dir $baseline_source_meta "bench-run" $"baseline-($baseline_ref)"
    maybe-cleanup-temp-dir $baseline_source_dir

    let candidate_source_meta = (build-worktree-source-meta)
    run-bench-suite $targets (project-dir) $candidate_dir $candidate_source_meta "bench-run" "candidate-worktree"

    let report = (compare-report $baseline_dir $candidate_dir $"baseline:($baseline_ref)" "candidate:worktree")
    $report | save -f $compare_file
    let asm_diff_summary = (generate-trial-asm-diffs $trial_dir $targets)
    let asm_diff_dir = ([$trial_dir "asm-diffs"] | path join)

    let trial_meta = {
        version: 1
        kind: "bench-trial"
        created_at: (iso-timestamp)
        trial_id: $trial_id
        targets: $targets
        baseline_ref: $baseline_ref
        baseline_dir: $baseline_dir
        candidate_dir: $candidate_dir
        comparison_file: $compare_file
        asm_diff_dir: $asm_diff_dir
        asm_diff_targets: ($asm_diff_summary | each { |summary| $summary.target })
    }
    $trial_meta | to json --indent 2 | save -f ([$trial_dir "trial.json"] | path join)

    print $"\nTrial saved in ($trial_dir)/"
    print $"Assembly diffs saved in ($asm_diff_dir)"
    print ""
    print $report
}

def main [] {
    print "Usage: bench.nu <command>

Commands:
  ssh <name>      SSH into a target
  sync [name]     Rsync project to target(s) (default: all)
  run [name] [--tag TAG]  Sync + run benchmarks on target(s) (default: all)
  trial [name] [--baseline-ref REF] [--label LABEL]  Run baseline-vs-worktree trial
  compare <baseline> <candidate> [target]  Compare tagged runs

Targets:
  local           Local machine (no SSH, runs zig build directly)
  orb-arm64       OrbStack NixOS VM (aarch64, Apple Silicon native)
  c7i             AWS c7i.large (Intel Sapphire Rapids)
  c7a             AWS c7a.large (AMD Genoa)
  c8g             AWS c8g.large (Graviton4)"
}
