const std = @import("std");

const X86Experiment = enum { none, medium_layout, medium_entry, small_paths };

const X86Variant = enum { auto, entry, high_regs, tiered, compact, medium_first, ymm_medium, straight_1k };

// The per-model default of the "auto" variant, from the p3-x86c fleet A/B
// (docs/results/p3-x86c.md). Keep in sync with src/x86_64/tuning.zig.
fn resolveX86Variant(cpu: []const u8, variant: X86Variant) X86Variant {
    const granite = std.mem.eql(u8, cpu, "graniterapids");
    const intel = granite or std.mem.eql(u8, cpu, "sapphirerapids");
    switch (variant) {
        .medium_first, .ymm_medium => if (granite) return variant,
        .straight_1k => if (intel) return variant,
        .auto => {},
        else => return variant,
    }
    // p3-x86d fleet A/B (docs/results/p3-x86d.md): straight_1k on Intel.
    if (intel) return .straight_1k;
    return if (std.mem.eql(u8, cpu, "znver4")) .tiered else .compact;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.option(bool, "link-libc", "Compatibility option: benchmarks always link libc");
    const rev = b.option(
        []const u8,
        "rev",
        "Revision label reported in bench-fastmem meta records",
    ) orelse "unknown";

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

    const x86_variant = b.option(X86Variant, "x86-variant", "x86 small ABI path (auto = per-model default)") orelse .auto;
    const x86_experiment = b.option(X86Experiment, "x86-experiment", "x86 fleet3 experiment") orelse .none;
    const x86_options = tuningOptions(b, x86_variant, x86_experiment);
    mod.addOptions("fastmem_options", x86_options);

    // Benchmark executable — always built ReleaseFast.
    const bench_opts = b.addOptions();
    // A fixed-size label: the binary layout (and so the code alignment of every
    // kernel) must not depend on the revision name (p3-x86d review P1).
    if (rev.len > 64) @panic("-Drev must be at most 64 bytes");
    var rev_buf: [64]u8 = @splat(0);
    @memcpy(rev_buf[0..rev.len], rev);
    bench_opts.addOption([64]u8, "rev_padded", rev_buf);

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
    const test_bin = b.step("test-bin", "Install the guard-page correctness binary");
    test_bin.dependOn(&install_correctness.step);
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

    // Private cross probes must not replace the public dependency module.
    std.debug.assert(b.modules.get("fastmem").? == mod);
    addX86Codegen(b, x86_options, x86_variant, x86_experiment);
    addStdExportTests(b, x86_options);

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

    const unit_install = b.addInstallArtifact(mod_tests, .{
        .dest_sub_path = "fastmem-unit-tests",
    });
    const unit_bin = b.step("test-unit-bin", "Install the unit test binary for cross execution");
    unit_bin.dependOn(&unit_install.step);
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(addExportTests(b, x86_options));
    // Compile the shipped binaries too: a module-graph error (for example
    // one file imported by two modules) only shows up when they build.
    test_step.dependOn(&bench_exe.step);
    test_step.dependOn(&correctness.step);
    test_step.dependOn(&libc_probe.step);
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
    const target_mod = b.createModule(.{
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

fn tuningOptions(b: *std.Build, variant: X86Variant, experiment: X86Experiment) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(X86Experiment, "x86_experiment", experiment);
    inline for (.{ "vec", "inline-max" }) |name| {
        options.addOption(
            ?u32,
            comptime "x86_" ++ replaceDash(name),
            b.option(u32, "x86-" ++ name, "Override the x86 tuning default"),
        );
    }
    inline for (.{
        "rep-movsb-min", "nt-min",             "rep-stosb-min",   "memset-nt-min",
        "alias-mask",    "rep-src-align-mask", "rep-fwd-gap-min",
    }) |name| {
        options.addOption(
            ?u64,
            comptime "x86_" ++ replaceDash(name),
            b.option(u64, "x86-" ++ name, "Override the x86 tuning default"),
        );
    }
    options.addOption(X86Variant, "x86_variant", variant);
    // aarch64 small-path overrides (src/aarch64/tuning.zig). "auto" keeps
    // the per-CPU-model default; these serve local A/B runs.
    inline for (.{ "copy", "move", "set" }) |op| {
        options.addOption(
            []const u8,
            "small_" ++ op,
            b.option(
                []const u8,
                "small-" ++ op,
                "aarch64 SVE " ++ op ++ " small path: auto|sve|neon|hybrid",
            ) orelse "auto",
        );
    }
    options.addOption(
        bool,
        "x86_small_masked_set",
        b.option(
            bool,
            "x86-small-masked-set",
            "Use masked small memset in LLVM builds",
        ) orelse true,
    );
    return options;
}

fn replaceDash(comptime name: []const u8) *const [name.len]u8 {
    comptime var result: [name.len]u8 = undefined;
    inline for (name, 0..) |c, i| result[i] = if (c == '-') '_' else c;
    return &result;
}

fn addX86Codegen(
    b: *std.Build,
    options: *std.Build.Step.Options,
    variant: X86Variant,
    experiment: X86Experiment,
) void {
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
        check.addArg(@tagName(resolveX86Variant(cpu, variant)));
        check.addFileArg(obj.getEmittedBin());
        check.addArgs(&.{ "--experiment", @tagName(experiment) });
        step.dependOn(&check.step);
        if (std.mem.eql(u8, cpu, "sapphirerapids") or std.mem.eql(u8, cpu, "graniterapids")) {
            const mutations = b.addSystemCommand(&.{"python3"});
            mutations.addFileArg(b.path("src/x86_64/test_check_codegen.py"));
            mutations.addArg(cpu);
            mutations.addArg(@tagName(resolveX86Variant(cpu, variant)));
            mutations.addFileArg(obj.getEmittedBin());
            mutations.addArgs(&.{ "--experiment", @tagName(experiment) });
            step.dependOn(&mutations.step);
        }
        const install = b.addInstallFile(obj.getEmittedBin(), b.fmt("codegen/{s}.o", .{cpu}));
        step.dependOn(&install.step);
    }
}

fn addExportTests(b: *std.Build, tuning: *std.Build.Step.Options) *std.Build.Step {
    const step = b.step("test-export", "Check opt-in memory symbols in linked ELF binaries");
    step.dependOn(addExportCollisionTests(b, tuning));
    step.dependOn(addArmByteTests(b));
    inline for (.{ "test_runtime.py", "test_audit.py" }) |script| {
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/" ++ script));
        step.dependOn(&check.step);
    }
    step.dependOn(addExportRecursionTests(b, tuning));
    const linux_host = b.graph.host.result.os.tag == .linux;
    for ([_][]const u8{ "aarch64", "x86_64" }) |arch| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = if (std.mem.eql(u8, arch, "x86_64")) "x86_64_v3" else "generic",
        }) catch unreachable);
        for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSafe }) |mode| {
            for ([_]bool{ false, true }) |libc| {
                for ([_]bool{ false, true }) |division| {
                    const name = b.fmt("export-{s}-{s}-libc{d}-div{d}", .{
                        arch, @tagName(mode), @intFromBool(libc), @intFromBool(division),
                    });
                    const fixture = exportFixture(b, tuning, target, mode, libc, division, true);
                    const exe = b.addExecutable(.{ .name = name, .root_module = fixture });
                    const check = b.addSystemCommand(&.{"python3"});
                    check.addFileArg(b.path("src/export/check.py"));
                    check.addArgs(&.{
                        "--arch", arch, "--division", if (division) "yes" else "no",
                    });
                    if (!libc and linux_host) check.addArg("--run");
                    check.addFileArg(exe.getEmittedBin());
                    step.dependOn(&check.step);
                }
            }
        }
        for ([_]bool{ false, true }) |enabled| {
            const mode: std.builtin.OptimizeMode = if (enabled) .Debug else .ReleaseFast;
            const fixture = exportFixture(b, tuning, target, mode, false, true, enabled);
            const exe = b.addExecutable(.{
                .name = b.fmt("export-{s}-{s}", .{
                    arch, if (enabled) "debug-llvm" else "disabled",
                }),
                .root_module = fixture,
                .use_llvm = true,
            });
            const check = b.addSystemCommand(&.{"python3"});
            check.addFileArg(b.path("src/export/check.py"));
            check.addArgs(&.{ "--arch", arch, "--division", "yes" });
            if (linux_host) check.addArg("--run");
            if (!enabled) check.addArg("--disabled");
            check.addFileArg(exe.getEmittedBin());
            step.dependOn(&check.step);
        }
        const debug = b.addObject(.{
            .name = b.fmt("export-debug-lowering-{s}", .{arch}),
            .use_llvm = false,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/export/debug.zig"),
                .target = target,
                .optimize = .Debug,
            }),
        });
        const debug_check = b.addSystemCommand(&.{"python3"});
        debug_check.addFileArg(b.path("src/export/check_debug.py"));
        debug_check.addArg(arch);
        debug_check.addFileArg(debug.getEmittedBin());
        step.dependOn(&debug_check.step);
        const refused = b.addObject(.{
            .name = b.fmt("export-refused-{s}", .{arch}),
            .use_llvm = false,
            .root_module = exportFixture(b, tuning, target, .Debug, false, false, true),
        });
        refused.expect_errors = .{
            .contains = "fastmem.exportSymbols requires the LLVM backend (use -fllvm in Debug)",
        };
        step.dependOn(&refused.step);
        const strong = b.addObject(.{
            .name = b.fmt("export-strong-{s}", .{arch}),
            .root_module = exportFixture(b, tuning, target, .ReleaseFast, false, true, true),
        });
        const strong_check = b.addSystemCommand(&.{"python3"});
        strong_check.addFileArg(b.path("src/export/check_object.py"));
        strong_check.addFileArg(strong.getEmittedBin());
        step.dependOn(&strong_check.step);
        // Dynamic executable and DSO: hidden definitions must stay local in both.
        const Link = enum { dynamic, shared, shared_no_rt };
        for ([_]Link{ .dynamic, .shared, .shared_no_rt }) |kind| {
            const shared = kind != .dynamic;
            const division = kind != .shared_no_rt;
            const fixture = exportFixture(b, tuning, target, .ReleaseFast, true, division, true);
            const artifact = if (shared)
                b.addLibrary(.{
                    .name = b.fmt("export-{s}-{s}", .{ @tagName(kind), arch }),
                    .root_module = fixture,
                    .linkage = .dynamic,
                })
            else
                b.addExecutable(.{
                    .name = b.fmt("export-dynamic-{s}", .{arch}),
                    .root_module = fixture,
                });
            const check = b.addSystemCommand(&.{"python3"});
            check.addFileArg(b.path("src/export/check.py"));
            check.addArgs(&.{ "--arch", arch, "--division", if (division) "yes" else "no" });
            if (kind == .shared_no_rt) artifact.bundle_compiler_rt = false;
            if (shared) check.addArg("--shared");
            check.addFileArg(artifact.getEmittedBin());
            step.dependOn(&check.step);
        }
    }
    for ([_][]const u8{ "neoverse_v1", "neoverse_v2", "neoverse_v3", "x86_64" }) |cpu| {
        const arch = if (std.mem.eql(u8, cpu, "x86_64")) "x86_64" else "aarch64";
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = cpu,
        }) catch unreachable);
        const exe = b.addExecutable(.{
            .name = b.fmt("export-{s}", .{cpu}),
            .root_module = exportFixture(b, tuning, target, .ReleaseFast, false, true, true),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check.py"));
        check.addArgs(&.{ "--arch", arch, "--division", "yes" });
        if (linux_host and std.mem.eql(u8, cpu, "x86_64")) check.addArg("--run");
        check.addFileArg(exe.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

fn exportFixture(
    b: *std.Build,
    tuning: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    libc: bool,
    division: bool,
    enabled: bool,
) *std.Build.Module {
    const kernel = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .no_builtin = true,
        .omit_frame_pointer = true,
    });
    kernel.addOptions("fastmem_options", tuning);
    const options = b.addOptions();
    options.addOption(bool, "division", division);
    options.addOption(bool, "enabled", enabled);
    const fixture = b.createModule(.{
        .root_source_file = b.path("src/export/consumer.zig"),
        .target = target,
        .optimize = mode,
        .link_libc = libc,
        .imports = &.{.{ .name = "fastmem", .module = kernel }},
    });
    fixture.addOptions("export_options", options);
    fixture.addCSourceFile(.{
        .file = b.path("src/export/consumer.c"),
        .flags = &.{ "-fno-builtin", "-fno-stack-protector" },
    });
    return fixture;
}

fn addStdExportTests(b: *std.Build, tuning: *std.Build.Step.Options) void {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("src/export/std_tests.py"));
    run.addArg(b.graph.zig_exe);
    run.addArg(b.graph.zig_lib_directory.path.?);
    run.addFileArg(b.path("src/root.zig"));
    run.addFileArg(tuning.getOutput());
    const step = b.step("test-export-std", "Check upstream std tests with memory exports");
    step.dependOn(&run.step);
}

fn addExportCollisionTests(b: *std.Build, tuning: *std.Build.Step.Options) *std.Build.Step {
    const step = b.step("test-export-collisions", "Reject competing memory definitions");
    for ([_][]const u8{ "generic", "neoverse_v3", "x86_64_v3" }) |cpu| {
        const arch = if (std.mem.eql(u8, cpu, "x86_64_v3")) "x86_64" else "aarch64";
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = b.fmt("{s}-linux-gnu", .{arch}),
            .cpu_features = cpu,
        }) catch unreachable);
        const kernel = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .no_builtin = true,
        });
        kernel.addOptions("fastmem_options", tuning);
        const Kind = enum { strong, weak, default, compiler_rt };
        for ([_]Kind{ .strong, .weak, .default, .compiler_rt }) |kind| {
            for ([_][]const u8{ "memcpy", "memmove", "memset" }) |symbol| {
                const options = b.addOptions();
                options.addOption(Kind, "kind", kind);
                options.addOption([]const u8, "symbol", symbol);
                const fixture = b.createModule(.{
                    .root_source_file = b.path("src/export/collision.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                    .imports = &.{.{ .name = "fastmem", .module = kernel }},
                });
                fixture.addOptions("collision_options", options);
                const obj = b.addObject(.{
                    .name = b.fmt("collision-{s}-{s}-{s}", .{
                        cpu, symbol, @tagName(kind),
                    }),
                    .root_module = fixture,
                });
                if (kind == .compiler_rt) obj.bundle_compiler_rt = true;
                obj.expect_errors = .{
                    .contains = b.fmt("exported symbol collision: {s}", .{symbol}),
                };
                step.dependOn(&obj.step);
            }
        }
    }
    return step;
}

fn addArmByteTests(b: *std.Build) *std.Build.Step {
    const step = b.step("test-export-arm-bytes", "Pin measured aarch64 kernel instruction bytes");
    const defaults = b.addOptions();
    inline for (.{ "copy", "move", "set" }) |op| {
        defaults.addOption([]const u8, "small_" ++ op, "auto");
    }
    for ([_][]const u8{ "generic", "neoverse_v1", "neoverse_v2", "neoverse_v3" }) |cpu| {
        const target = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = "aarch64-linux-gnu",
            .cpu_features = cpu,
        }) catch unreachable);
        const kernel = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .no_builtin = true,
        });
        kernel.addOptions("fastmem_options", defaults);
        const obj = b.addObject(.{
            .name = b.fmt("kernel-bytes-{s}", .{cpu}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/export/kernel_bytes.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "fastmem", .module = kernel }},
            }),
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check_kernel_bytes.py"));
        check.addArg(cpu);
        check.addFileArg(obj.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

fn addExportRecursionTests(b: *std.Build, tuning: *std.Build.Step.Options) *std.Build.Step {
    const step = b.step(
        "test-export-recursion",
        "Audit std helpers and local intrinsic suppression",
    );
    const target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "x86_64-linux-gnu",
        .cpu_features = "x86_64",
    }) catch unreachable);
    const bad = b.addExecutable(.{
        .name = "export-recursive-std",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/export/recursion.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const reject = b.addSystemCommand(&.{"python3"});
    reject.addFileArg(b.path("src/export/check_recursion_fixture.py"));
    reject.addFileArg(bad.getEmittedBin());
    step.dependOn(&reject.step);
    for ([_]std.builtin.OptimizeMode{ .ReleaseFast, .ReleaseSafe, .Debug }) |mode| {
        const fixture = exportFixture(b, tuning, target, mode, false, true, true);
        // Prove that each fallback also resists intrinsic formation locally.
        fixture.import_table.get("fastmem").?.no_builtin = false;
        const exe = b.addExecutable(.{
            .name = b.fmt("export-local-suppression-{s}", .{@tagName(mode)}),
            .root_module = fixture,
            .use_llvm = true,
        });
        const check = b.addSystemCommand(&.{"python3"});
        check.addFileArg(b.path("src/export/check.py"));
        check.addArgs(&.{ "--arch", "x86_64", "--division", "yes" });
        if (b.graph.host.result.os.tag == .linux) check.addArg("--run");
        check.addFileArg(exe.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}
