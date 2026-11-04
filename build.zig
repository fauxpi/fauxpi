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
    if (@hasField(std.Build, "args")) {
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

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
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
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
