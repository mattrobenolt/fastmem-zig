const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.option(bool, "link-libc", "Compatibility option: benchmarks always link libc");
    const rev = b.option([]const u8, "rev", "Revision label reported in bench-fastmem meta records") orelse "unknown";

    // no_builtin: LLVM must not idiom-recognize fastmem's own loops into
    // memcpy/memset calls (recursion under the export layer).
    // omit_frame_pointer: the C-ABI kernels must not pay x29/x30 prologues
    // where a frame exists (docs/fastmem-plan.md Facts).
    const mod = b.addModule("fastmem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .no_builtin = true,
        .omit_frame_pointer = true,
    });

    const x86_options = x86Options(b);
    mod.addOptions("fastmem_options", x86_options);

    // Benchmark executable — always built ReleaseFast.
    const bench_opts = b.addOptions();
    bench_opts.addOption([]const u8, "rev", rev);

    const bench_exe = b.addExecutable(.{
        .name = "bench-fastmem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_fastmem.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "fastmem", .module = mod },
                .{ .name = "bench_options", .module = bench_opts.createModule() },
            },
        }),
    });
    bench_exe.bundle_compiler_rt = true;
    bench_exe.root_module.linkSystemLibrary("dl", .{});
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run fastmem benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);

    const libc_probe_mod = b.createModule(.{
        .root_source_file = b.path("src/libc_probe.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    if (target.result.os.tag == .linux and target.result.abi.isGnu())
        libc_probe_mod.linkSystemLibrary("dl", .{});

    const libc_probe = b.addExecutable(.{
        .name = "libc-probe",
        .root_module = libc_probe_mod,
    });
    const install_libc_probe = b.addInstallArtifact(libc_probe, .{});
    // `zig build install` ships libc-probe next to bench-fastmem for the
    // selected -Dtarget/-Dcpu, per docs/bench-design.md.
    b.getInstallStep().dependOn(&install_libc_probe.step);
    const libc_probe_step = b.step("libc-probe", "Build the libc symbol probe");
    libc_probe_step.dependOn(&install_libc_probe.step);

    // Match benchmark libc linkage until the kernels remove libc delegation.
    const correctness = b.addExecutable(.{
        .name = "fastmem-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .imports = &.{.{ .name = "fastmem", .module = mod }},
        }),
    });
    const install_correctness = b.addInstallArtifact(correctness, .{});
    b.getInstallStep().dependOn(&install_correctness.step);
    b.step("test-bin", "Install the guard-page correctness binary").dependOn(&install_correctness.step);
    const guard_cmd = b.addRunArtifact(correctness);
    if (b.args) |args| guard_cmd.addArgs(args);
    b.step("test-guard", "Run the full guard-page matrix").dependOn(&guard_cmd.step);

    // Assembly output for codegen inspection.
    addAsmStep(b, x86_options, target, "asm", "Emit assembly for the current (or -Dtarget) target");

    const asm_all_step = b.step("asm-all", "Emit assembly for all key targets");
    const asm_targets = [_][]const u8{
        "aarch64-linux-gnu",
        "aarch64-linux-musl",
        "x86_64-linux-gnu",
        "x86_64-linux-musl",
        "aarch64-macos-none",
    };
    for (asm_targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
        }) catch unreachable);
        const obj = addAsmObject(b, x86_options, resolved, triple);
        asm_all_step.dependOn(obj);
    }

    addX86Codegen(b, x86_options);

    // Tests. The fastmem test module takes an explicit optimize so a
    // release-mode test build can dodge the 0.16.0 self-hosted-backend
    // bug in fuzz mode (ziglang/zig#30655) — see the `fuzz` Justfile
    // recipe. The library module itself stays null-optimize and inherits
    // each consumer's mode (ReleaseFast for bench, etc.).
    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            // Match the production module so tests build the same code.
            .no_builtin = true,
            .omit_frame_pointer = true,
        }),
    });

    mod_tests.root_module.addOptions("fastmem_options", x86_options);

    const unit_install = b.addInstallArtifact(mod_tests, .{ .dest_sub_path = "fastmem-unit-tests" });
    b.step("test-unit-bin", "Install the unit test binary for cross execution").dependOn(&unit_install.step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const bench_tests = b.addTest(.{ .root_module = bench_exe.root_module });
    bench_tests.bundle_compiler_rt = true;
    const run_bench_tests = b.addRunArtifact(bench_tests);
    test_step.dependOn(&run_bench_tests.step);
}

fn addAsmObject(
    b: *std.Build,
    x86_options: *std.Build.Step.Options,
    resolved_target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step {
    // Create a target-specific fastmem module so comptime builtins
    // (cpu.model, cpu.arch, etc.) reflect the cross-compilation target.
    const target_mod = b.addModule("fastmem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = resolved_target,
        .no_builtin = true,
        .omit_frame_pointer = true,
    });

    target_mod.addOptions("fastmem_options", x86_options);

    const obj = b.addObject(.{
        .name = "fastmem-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/asm_probe.zig"),
            .target = resolved_target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "fastmem", .module = target_mod },
            },
        }),
    });

    const asm_file = obj.getEmittedAsm();
    const ll_file = obj.getEmittedLlvmIr();

    var asm_name_buf: [64]u8 = undefined;
    const asm_name = std.fmt.bufPrint(&asm_name_buf, "asm/{s}.s", .{name}) catch unreachable;
    var ll_name_buf: [64]u8 = undefined;
    const ll_name = std.fmt.bufPrint(&ll_name_buf, "asm/{s}.ll", .{name}) catch unreachable;

    const install_asm = b.addInstallFile(asm_file, asm_name);
    const install_ll = b.addInstallFile(ll_file, ll_name);

    // Return a step that depends on both installs.
    const group = b.allocator.create(std.Build.Step) catch @panic("OOM");
    group.* = std.Build.Step.init(.{
        .id = .custom,
        .name = name,
        .owner = b,
    });
    group.dependOn(&install_asm.step);
    group.dependOn(&install_ll.step);
    return group;
}

fn addAsmStep(
    b: *std.Build,
    x86_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    step_name: []const u8,
    description: []const u8,
) void {
    const t = target.result;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}-{s}-{s}", .{
        @tagName(t.cpu.arch),
        @tagName(t.os.tag),
        @tagName(t.abi),
    }) catch unreachable;

    const obj_step = addAsmObject(b, x86_options, target, name);
    const step = b.step(step_name, description);
    step.dependOn(obj_step);
}

fn x86Options(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    inline for (.{ "vec", "inline-max" }) |name| {
        options.addOption(?u32, comptime "x86_" ++ replaceDash(name), b.option(u32, "x86-" ++ name, "Override the x86 tuning default"));
    }
    inline for (.{ "rep-movsb-min", "nt-min", "rep-stosb-min", "memset-nt-min", "alias-mask", "rep-src-align-mask", "rep-fwd-gap-min" }) |name| {
        options.addOption(?u64, comptime "x86_" ++ replaceDash(name), b.option(u64, "x86-" ++ name, "Override the x86 tuning default"));
    }
    options.addOption(bool, "x86_small_masked_set", b.option(bool, "x86-small-masked-set", "Use masked small memset in LLVM builds") orelse true);
    return options;
}

fn replaceDash(comptime name: []const u8) *const [name.len]u8 {
    comptime var result: [name.len]u8 = undefined;
    inline for (name, 0..) |c, i| result[i] = if (c == '-') '_' else c;
    return &result;
}

fn addX86Codegen(b: *std.Build, options: *std.Build.Step.Options) void {
    const step = b.step("codegen-x86", "Check x86 vector widths, ABI entries, and symbol independence");
    for ([_][]const u8{ "sapphirerapids", "graniterapids", "znver4", "znver5", "x86_64_v3" }) |cpu| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = "x86_64-linux-gnu",
            .cpu_features = cpu,
        }) catch unreachable);
        const kernel = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .no_builtin = true,
            .omit_frame_pointer = true,
        });
        kernel.addOptions("fastmem_options", options);
        const obj = b.addObject(.{
            .name = b.fmt("probe-{s}", .{cpu}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/x86_64/codegen.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .omit_frame_pointer = true,
                .imports = &.{.{ .name = "fastmem", .module = kernel }},
            }),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/x86_64/check_codegen.py"));
        check.addArg(cpu);
        check.addFileArg(obj.getEmittedBin());
        step.dependOn(&check.step);
        const install = b.addInstallFile(obj.getEmittedBin(), b.fmt("codegen/{s}.o", .{cpu}));
        step.dependOn(&install.step);
    }
}
