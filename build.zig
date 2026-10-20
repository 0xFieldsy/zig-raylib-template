const std = @import("std");

pub fn build(b: *std.Build) void {
    // Avoid native CPU features to make the binaries portable.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zetris", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.step("test", "Run tests");
    const artifact = b.addTest(.{ .root_module = mod });
    tests.dependOn(&b.addRunArtifact(artifact).step);

    const exe = addApp(b, target, optimize, mod) orelse return;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the app").dependOn(&run.step);
}

fn addApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
) ?*std.Build.Step.Compile {
    const libs = addRaylib(b, target, optimize) orelse return null;

    return b.addExecutable(.{
        .name = b.fmt("zetris-{s}-{s}-{s}", .{
            @tagName(target.result.cpu.arch),
            @tagName(target.result.os.tag),
            @tagName(target.result.abi),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zetris", .module = mod },
                .{ .name = "raylib", .module = libs.raylib },
                .{ .name = "raygui", .module = libs.raygui },
            },
        }),
    });
}

const Raylib = struct { raylib: *std.Build.Module, raygui: *std.Build.Module };

fn addRaylib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?Raylib {
    const raylib_dep = b.lazyDependency(
        "raylib_zig",
        .{ .target = target, .optimize = optimize },
    ) orelse return null;

    const raylib = raylib_dep.module("raylib");
    const raylib_c = raylib_dep.artifact("raylib");
    if (target.result.os.tag == .linux) {
        // An explicit -Dtarget OS skips Zig's native header/library discovery.
        // Only use host paths for a matching target without a supplied sysroot.
        const host = b.graph.host.result;
        if (!target.query.isNativeOs() and b.sysroot == null and
            target.result.cpu.arch == host.cpu.arch and
            target.result.os.tag == host.os.tag and
            target.result.abi == host.abi)
        {
            const paths = std.zig.system.NativePaths.detect(
                b.allocator,
                b.graph.io,
                &host,
                &b.graph.environ_map,
            ) catch @panic("unable to detect native search paths");
            // Keep Zig's target libc headers ahead of the host headers.
            for (paths.include_dirs.items) |path| {
                std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch continue;
                raylib_c.root_module.addAfterIncludePath(.{ .cwd_relative = path });
            }
            for (paths.lib_dirs.items) |path| {
                std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch continue;
                raylib.addLibraryPath(.{ .cwd_relative = path });
            }
        }

        // Zig 0.16 can bundle Linux shared libraries into a static C archive.
        // Link them through the Zig module instead, at the final executable step.
        var i: usize = 0;
        while (i < raylib_c.root_module.link_objects.items.len) {
            if (raylib_c.root_module.link_objects.items[i] == .system_lib) {
                const library = raylib_c.root_module.link_objects.orderedRemove(i);
                raylib.link_objects.append(b.allocator, library) catch @panic("out of memory");
            } else i += 1;
        }
    }

    if (target.result.os.tag == .macos) {
        // Framework/library search paths on the C archive are not inherited by the final executable.
        // Forward raylib's cross-compilation SDK paths.
        for (raylib_c.root_module.include_dirs.items) |include_dir| {
            switch (include_dir) {
                .framework_path => |path| raylib.addFrameworkPath(path),
                .framework_path_system => |path| raylib.addSystemFrameworkPath(path),
                else => {},
            }
        }
        for (raylib_c.root_module.lib_paths.items) |path| raylib.addLibraryPath(path);
    }

    // raygui imports the module above, and its C code is compiled into the raylib archive.
    return .{ .raylib = raylib, .raygui = raylib_dep.module("raygui") };
}
