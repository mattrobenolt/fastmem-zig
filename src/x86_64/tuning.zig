//! Model-specific defaults from docs/research/x86_64-design.md, section 5.4.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("fastmem_options");
const cpu = std.Target.x86.cpu;

pub const available = builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx2);
pub const avx512 = available and builtin.cpu.has(.x86, .avx512bw);
pub const Tuning = struct {
    vec: u32 = if (avx512) 64 else 32,
    medium_vec: u32 = 64,
    abi_alignment: u32 = 16,
    medium_first: bool = false,
    abi_move_max: u32 = 512,
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
    .medium_vec = if (variant == .ymm_medium) 32 else defaults.medium_vec,
    .abi_alignment = if (variant == .medium_first) 64 else defaults.abi_alignment,
    .medium_first = variant == .medium_first,
    .abi_move_max = if (variant == .straight_1k) 1024 else defaults.abi_move_max,
    .rep_fwd_gap_min = options.x86_rep_fwd_gap_min orelse defaults.rep_fwd_gap_min,
    .rep_movsb_min = options.x86_rep_movsb_min orelse defaults.rep_movsb_min,
    .nt_min = options.x86_nt_min orelse defaults.nt_min,
    .rep_stosb_min = options.x86_rep_stosb_min orelse defaults.rep_stosb_min,
    .memset_nt_min = options.x86_memset_nt_min orelse defaults.memset_nt_min,
    .alias_mask = options.x86_alias_mask orelse defaults.alias_mask,
    .rep_src_align_mask = options.x86_rep_src_align_mask orelse defaults.rep_src_align_mask,
};
// Experiments remain model-local. The default keeps the measured kernels.
pub const medium_layout = builtin.cpu.model == &cpu.graniterapids and
    options.x86_experiment == .medium_layout;
pub const medium_entry = builtin.cpu.model == &cpu.graniterapids and
    options.x86_experiment == .medium_entry;
pub const short_scalar = builtin.cpu.model == &cpu.znver4 and
    options.x86_experiment == .small_paths;
pub const inline_short_first = builtin.cpu.model == &cpu.sapphirerapids and
    options.x86_experiment == .small_paths;
pub const vec = selected.vec;
pub const inline_max = options.x86_inline_max orelse 4 * vec;
// Model gates also apply to explicit experiments. Other CPUs retain their defaults.
// Keep the resolver in build.zig consistent with this table.
// p3-x86d fleet A/B (docs/results/p3-x86d.md): straight_1k on SPR and GNR.
const intel_model = builtin.cpu.model == &cpu.graniterapids or
    builtin.cpu.model == &cpu.sapphirerapids;
const model_variant = if (builtin.cpu.model == &cpu.znver4)
    .tiered
else if (intel_model)
    .straight_1k
else
    .compact;
pub const variant = switch (options.x86_variant) {
    .auto => model_variant,
    .medium_first, .ymm_medium => if (builtin.cpu.model == &cpu.graniterapids)
        options.x86_variant
    else
        model_variant,
    .straight_1k => if (builtin.cpu.model == &cpu.graniterapids or
        builtin.cpu.model == &cpu.sapphirerapids)
        options.x86_variant
    else
        model_variant,
    else => options.x86_variant,
};
pub const high_regs = variant != .entry and avx512 and
    builtin.cpu.has(.x86, .avx512vl) and vec == 64;
pub const reordered = high_regs and variant != .high_regs;
pub const compact_short = variant != .tiered;
pub const small_masked_set = options.x86_small_masked_set;
pub const name: []const u8 = if (reordered)
    "x86-avx512-" ++ @tagName(variant) ++ "-v3"
else if (high_regs)
    "x86-avx512-high-regs-v2"
else if (vec == 64)
    "x86-avx512-entry-v2"
else
    "x86-avx2-entry-v2";

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
