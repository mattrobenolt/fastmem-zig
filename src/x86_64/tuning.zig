//! Model-specific defaults from docs/research/x86_64-design.md, section 5.4.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("fastmem_options");
const cpu = std.Target.x86.cpu;

pub const available = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2);
pub const avx512 = available and builtin.cpu.has(.x86, .avx512bw);
pub const Tuning = struct {
    vec: u32 = if (avx512) 64 else 32,
    rep_movsb_min: ?u64 = null,
    // Null preserves the measured vector policy for every forward overlap.
    rep_fwd_gap_min: ?u64 = null,
    nt_min: ?u64 = null,
    rep_stosb_min: ?u64 = null,
    memset_nt_min: ?u64 = null,
    alias_mask: u64 = 0xf00,
    rep_src_align_mask: u64 = 0xe00,
};

// Cache thresholds describe the fleet instance sizes, not every CPU with this model.
const defaults: Tuning = if (builtin.cpu.model == &cpu.sapphirerapids) .{
    .rep_movsb_min = 16384,
    .nt_min = 0x3580000,
    .rep_stosb_min = 2048,
    .memset_nt_min = 0x3580000,
} else if (builtin.cpu.model == &cpu.graniterapids) .{
    .rep_movsb_min = 16384,
    .nt_min = 0xf100000,
    .rep_stosb_min = 2048,
    .memset_nt_min = 0xf100000,
} else if (builtin.cpu.model == &cpu.znver4 or builtin.cpu.model == &cpu.znver5) .{
    // AMD uses temporal stores at exactly 12 MiB. Neither AMD model uses REP.
    .nt_min = 0xc00001,
} else if (builtin.cpu.model == &cpu.skylake_avx512 or
    builtin.cpu.model == &cpu.cascadelake or
    builtin.cpu.model == &cpu.icelake_client or
    builtin.cpu.model == &cpu.icelake_server) .{
    .vec = 32,
} else .{};

pub const selected: Tuning = .{
    .vec = options.x86_vec orelse defaults.vec,
    .rep_fwd_gap_min = options.x86_rep_fwd_gap_min orelse defaults.rep_fwd_gap_min,
    .rep_movsb_min = options.x86_rep_movsb_min orelse defaults.rep_movsb_min,
    .nt_min = options.x86_nt_min orelse defaults.nt_min,
    .rep_stosb_min = options.x86_rep_stosb_min orelse defaults.rep_stosb_min,
    .memset_nt_min = options.x86_memset_nt_min orelse defaults.memset_nt_min,
    .alias_mask = options.x86_alias_mask orelse defaults.alias_mask,
    .rep_src_align_mask = options.x86_rep_src_align_mask orelse defaults.rep_src_align_mask,
};
pub const vec = selected.vec;
pub const inline_max = options.x86_inline_max orelse 4 * vec;
// H5 move masks and H11 high registers stay disabled until fleet measurements justify variants.
// Future flags belong here, beside the small memset policy.
pub const small_masked_set = options.x86_small_masked_set;
pub const name: []const u8 = if (vec == 64) "x86-avx512-v1" else "x86-avx2-v1";

comptime {
    if (available) {
        if (selected.rep_fwd_gap_min) |gap| {
            if (gap < 256) @compileError("x86-rep-fwd-gap-min must be at least 256");
        }
        if (vec != 32 and vec != 64) @compileError("x86-vec must be 32 or 64");
        if (vec == 64 and !avx512) @compileError("x86-vec=64 requires AVX-512BW");
        if (inline_max > 8 * vec) @compileError("x86-inline-max exceeds the straight-line classes");
    }
}
