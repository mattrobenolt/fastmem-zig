const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_libc = b.option(bool, "link-libc", "Link libc to enable libc comparison in benchmarks") orelse false;

    const mod = b.addModule("fastmem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "fastmem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fastmem", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    // Benchmark executable — always built ReleaseFast.
    const bench_opts = b.addOptions();
    bench_opts.addOption(bool, "link_libc", link_libc);

    const bench_exe = b.addExecutable(.{
        .name = "bench-fastmem",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_fastmem.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = if (link_libc) true else null,
            .imports = &.{
                .{ .name = "fastmem", .module = mod },
                .{ .name = "bench_options", .module = bench_opts.createModule() },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run fastmem benchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_cmd.addArgs(args);

    // Assembly output for codegen inspection.
    addAsmStep(b, target, "asm", "Emit assembly for the current (or -Dtarget) target");

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
        const obj = addAsmObject(b, resolved, triple);
        asm_all_step.dependOn(obj);
    }

    // Tests.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn addAsmObject(
    b: *std.Build,
    resolved_target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step {
    // Create a target-specific fastmem module so comptime builtins
    // (cpu.model, cpu.arch, etc.) reflect the cross-compilation target.
    const target_mod = b.addModule("fastmem", .{
        .root_source_file = b.path("src/root.zig"),
        .target = resolved_target,
    });

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

    const obj_step = addAsmObject(b, target, name);
    const step = b.step(step_name, description);
    step.dependOn(obj_step);
}
