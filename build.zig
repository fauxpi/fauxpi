const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const explicit_optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)");
    const optimize: std.builtin.OptimizeMode = explicit_optimize orelse .ReleaseFast;

    // The UI toolkit the window is drawn with.
    const kete = b.dependency("kete", .{ .target = target, .optimize = optimize }).module("kete");

    // The version is the date of the commit built (2026.11.5), so it goes up by itself; and the
    // commit, to say exactly which build it is.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", gitVersion(b));
    build_info.addOption([]const u8, "commit", gitOutput(b, &.{ "rev-parse", "--short", "HEAD" }) orelse "unknown");

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("kete", kete);
    root_mod.addOptions("build_info", build_info);

    // Debug builds use LLVM too: Zig's self-hosted x86-64 backend crashes compiling the
    // 128-bit `cmpxchg` that emulates `STXP` (src/cpu/atomic_ram.zig).
    // https://codeberg.org/ziglang/zig/issues/37289
    const exe = b.addExecutable(.{
        .name = "fauxpi",
        .root_module = root_mod,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // `zig build run -- <args>` passes them on.
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the Raspberry Pi Zero simulator");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    test_mod.addImport("kete", b.dependency("kete", .{ .target = target, .optimize = .Debug }).module("kete"));
    test_mod.addOptions("build_info", build_info);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        // See the `use_llvm` comment on `exe` (https://codeberg.org/ziglang/zig/issues/37289).
        .use_llvm = true,
    });
    // Debug builds keep several copies of the large SoC and CPU structs on the stack, which
    // overflows macOS's fixed 8 MiB main-thread stack.
    unit_tests.stack_size = 64 * 1024 * 1024;
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    addBench(b, exe);
}

/// The benchmark (bench/): a bare-metal kernel.img for the Pi Zero that runs tests of the CPU, the
/// DMA engine, V3D and the HVS, and a runner that boots it in FauxPi (headless, a test a boot) and
/// reports where the time went, as JSON. `zig build bench -- --help` says how to use it.
fn addBench(b: *std.Build, fauxpi: *std.Build.Step.Compile) void {
    const tests_mod = b.createModule(.{ .root_source_file = b.path("bench/tests.zig") });

    // The Pi Zero's ARM1176, with no operating system.
    const arm = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .freestanding,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
    });
    const guest_mod = b.createModule(.{
        .root_source_file = b.path("bench/baremetal/main.zig"),
        .target = arm,
        .optimize = .ReleaseFast,
    });
    guest_mod.addImport("bench_tests", tests_mod);
    const qpu_mod = b.createModule(.{ .root_source_file = b.path("src/vc4/qpu.zig"), .target = arm, .optimize = .ReleaseFast });
    const scene_mod = b.createModule(.{ .root_source_file = b.path("bench/scene.zig"), .target = arm, .optimize = .ReleaseFast });
    scene_mod.addImport("qpu", qpu_mod);
    guest_mod.addImport("qpu", qpu_mod);
    guest_mod.addImport("scene", scene_mod);
    const guest = b.addExecutable(.{ .name = "fauxpi-bench", .root_module = guest_mod });
    guest.setLinkerScript(b.path("bench/baremetal/link.ld"));
    guest.entry = .{ .symbol_name = "_start" };
    const kernel_img = b.addObjCopy(guest.getEmittedBin(), .{ .format = .binary, .basename = "kernel.img" });
    const install_kernel = b.addInstallFile(kernel_img.getOutput(), "bench/kernel.img");
    b.step("bench-kernel", "Build the bare-metal benchmark (zig-out/bench/kernel.img)").dependOn(&install_kernel.step);

    // The Linux benchmark's init, for the Pi Zero's Linux (static, no C library).
    const arm_linux = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .eabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm1176jzf_s },
    });
    const linux_qpu = b.createModule(.{ .root_source_file = b.path("src/vc4/qpu.zig"), .target = arm_linux, .optimize = .ReleaseFast });
    const linux_scene = b.createModule(.{ .root_source_file = b.path("bench/scene.zig"), .target = arm_linux, .optimize = .ReleaseFast });
    linux_scene.addImport("qpu", linux_qpu);
    const init_mod = b.createModule(.{
        .root_source_file = b.path("bench/linux/init.zig"),
        .target = arm_linux,
        .optimize = .ReleaseFast,
    });
    init_mod.addImport("scene", linux_scene);
    init_mod.addImport("bench_tests", tests_mod);
    const init = b.addExecutable(.{ .name = "init", .root_module = init_mod });
    const install_init = b.addInstallFile(init.getEmittedBin(), "bench/init");
    b.step("bench-init", "Build the Linux benchmark's init (zig-out/bench/init)").dependOn(&install_init.step);

    const host = b.graph.host;
    const mkimage = b.addExecutable(.{ .name = "fauxpi-mkimage", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/mkimage.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
    }) });
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("bench/run.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
    });
    runner_mod.addImport("bench_tests", tests_mod);
    const runner = b.addExecutable(.{ .name = "fauxpi-bench", .root_module = runner_mod });

    const run = b.addRunArtifact(runner);
    run.addPrefixedFileArg("--fauxpi=", fauxpi.getEmittedBin());
    run.addPrefixedFileArg("--kernel=", kernel_img.getOutput());
    run.addPrefixedFileArg("--mkimage=", mkimage.getEmittedBin());
    run.addPrefixedFileArg("--init=", init.getEmittedBin());
    run.addPrefixedFileArg("--linux-config=", b.path("bench/linux/bench.config"));
    run.addPassthruArgs();
    run.has_side_effects = true;
    run.stdio = .inherit;
    const step = b.step("bench", "Benchmark FauxPi: boot the bare-metal tests in it and report (-- --help)");
    step.dependOn(&run.step);
    step.dependOn(&install_kernel.step);

    const unit = b.addTest(.{ .root_module = runner_mod });
    const bench_tests_step = b.step("bench-test", "Test the benchmark's runner");
    bench_tests_step.dependOn(&b.addRunArtifact(unit).step);
}

/// What `git <args>` prints in the source tree, trimmed; null without git or its history.
fn gitOutput(b: *std.Build, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, "git") catch return null;
    argv.appendSlice(b.allocator, args) catch return null;
    var code: u8 = 0;
    const out = b.runAllowFail(argv.items, &code, .ignore) catch return null;
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

/// The date of the commit built as a version: 2026-11-05 is 2026.11.5.
fn gitVersion(b: *std.Build) []const u8 {
    const date = gitOutput(b, &.{ "log", "-1", "--format=%cs" }) orelse return "unknown";
    var parts = std.mem.splitScalar(u8, date, '-');
    const year = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return "unknown";
    const month = std.fmt.parseInt(u8, parts.next() orelse "", 10) catch return "unknown";
    const day = std.fmt.parseInt(u8, parts.next() orelse "", 10) catch return "unknown";
    return b.fmt("{d}.{d}.{d}", .{ year, month, day });
}
