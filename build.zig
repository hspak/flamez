//! Build graph for the Flamez executable, its eBPF object, and the complete test root.

const std = @import("std");

const log = std.log.scoped(.build);

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_module = b.addModule("flamez", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_dep = if (target.result.os.tag == .linux)
        b.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
            .raudio = false,
            .rmodels = false,
            // Avoid an X11 fallback so development runs use the active Wayland session.
            .linux_display_backend = .Wayland,
        })
    else
        b.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
            .raudio = false,
            .rmodels = false,
        });
    const raylib = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");
    if (target.result.os.tag == .linux) {
        // Upstream hack: raylib doesn't expose a way for us to set the wayland
        // app_id because it runs `glfwDefaultWindowHints()` which wipes the
        // user defined value. There's also no entrypoint for the user to set
        // it before raylib creates a window. Could upstream this one day, but
        // not in its current state.
        raylib_artifact.root_module.addCMacro("RAYLIB_WAYLAND_APP_ID", "\"flamez\"");
        moveRaylibLinuxLibraries(raylib_artifact, raylib);
    }

    // Linux embeds its eBPF loader; macOS uses a small libproc ABI bridge.
    const enable_ebpf = target.result.os.tag == .linux;
    const enable_fps_counter = b.option(
        bool,
        "fps-counter",
        "Draw a green FPS counter beside the footer title",
    ) orelse false;
    const enable_perf_telemetry = b.option(
        bool,
        "perf-telemetry",
        "Log one performance summary line per second and a session total",
    ) orelse false;
    const enable_msaa = b.option(
        bool,
        "msaa",
        "Enable 4x multisample anti-aliasing",
    ) orelse true;
    const require_macos_endpoint_security = b.option(
        bool,
        "macos-require-endpoint-security",
        "Reject macOS launch unless exact Endpoint Security capture activates",
    ) orelse false;
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Run tests whose names contain this substring",
    );
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};
    const build_options = b.addOptions();
    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "ebpf", enable_ebpf);
    build_options.addOption(bool, "fps_counter", enable_fps_counter);
    build_options.addOption(bool, "perf_telemetry", enable_perf_telemetry);
    build_options.addOption(bool, "msaa", enable_msaa);
    build_options.addOption(
        bool,
        "macos_require_endpoint_security",
        require_macos_endpoint_security,
    );
    const footer_font_files = b.addWriteFiles();
    const clay_dep = zclay_dep.builder.dependency("clay", .{});
    const footer_font_source = footer_font_files.add(
        "footer_font.zig",
        "pub const ttf = @embedFile(\"RobotoMono-Medium.ttf\");\n",
    );
    _ = footer_font_files.addCopyFile(
        clay_dep.path("examples/raylib-multi-context/resources/RobotoMono-Medium.ttf"),
        "RobotoMono-Medium.ttf",
    );
    const footer_font = b.createModule(.{ .root_source_file = footer_font_source });

    const exe = b.addExecutable(.{
        .name = "flamez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const app_modules = [_]*std.Build.Module{ main_module, exe.root_module };
    for (app_modules) |module| {
        module.addImport("zclay", zclay_dep.module("zclay"));
        module.addImport("raylib", raylib);
        module.addImport("footer_font", footer_font);
        module.addOptions("build_options", build_options);
        if (target.result.os.tag == .macos) addMacosSdkPaths(b, module);
    }
    if (target.result.os.tag == .macos) {
        addMacosProcessShim(b, main_module, true);
        addMacosProcessShim(b, exe.root_module, false);
    }

    if (enable_ebpf) {
        const bpf_compile = b.addSystemCommand(&.{
            "clang",
            "-target",
            "bpf",
            "-O2",
            "-g",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
        });
        bpf_compile.addFileArg(b.path("src/flamez.bpf.c"));
        bpf_compile.addFileInput(b.path("src/flamez_event.h"));
        bpf_compile.addArg("-o");
        const bpf_object = bpf_compile.addOutputFileArg("flamez.bpf.o");
        build_options.addOptionPath("bpf_object", bpf_object);
        const install_bpf = b.addInstallFile(bpf_object, "share/flamez/flamez.bpf.o");
        b.getInstallStep().dependOn(&install_bpf.step);

        for (app_modules) |module| {
            module.addCSourceFile(.{
                .file = b.path("src/ebpf_shim.c"),
                .flags = &.{
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    if (module == main_module)
                        "-DFLAMEZ_CAPTURE_TEST=1"
                    else
                        "-DFLAMEZ_CAPTURE_TEST=0",
                },
            });
            module.linkSystemLibrary("bpf", .{});
            module.link_libc = true;
        }
        addLinuxCaptureTests(b, main_module);
    } else {
        build_options.addOption([]const u8, "bpf_object", "");
    }

    b.installArtifact(exe);
    const install_analysis_schema = b.addInstallFile(
        b.path("schema/flamez-analysis-v1.schema.json"),
        "share/flamez/flamez-analysis-v1.schema.json",
    );
    const install_analysis_metrics = b.addInstallFile(
        b.path("schema/flamez-analysis-v1.md"),
        "share/flamez/flamez-analysis-v1.md",
    );
    b.getInstallStep().dependOn(&install_analysis_schema.step);
    b.getInstallStep().dependOn(&install_analysis_metrics.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    // Run from the installation tree so the BPF object layout matches production.
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // main explicitly imports the tracer and every other test-bearing module.
    const main_tests = b.addTest(.{
        .root_module = main_module,
        .filters = test_filters,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&main_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_main_tests.step);
}

fn addLinuxCaptureTests(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{
        .file = b.path("src/macos_cpu.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-DFLAMEZ_MACOS_CPU_TEST=1",
        },
    });
    module.addCSourceFile(.{
        .file = b.path("src/flamez.bpf.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unknown-attributes",
            "-DFLAMEZ_BPF_TEST=1",
        },
    });
}

fn addMacosProcessShim(
    b: *std.Build,
    module: *std.Build.Module,
    test_build: bool,
) void {
    module.addCSourceFile(.{
        .file = b.path("src/macos_cpu.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
        },
    });
    module.addCSourceFile(.{
        .file = b.path("src/macos_shim.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
        },
    });
    module.addCSourceFile(.{
        .file = b.path("src/macos_es_shim.c"),
        .flags = if (test_build)
            &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fblocks",
                "-DFLAMEZ_TEST=1",
            }
        else
            &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-fblocks",
            },
    });
    module.addIncludePath(b.path("src"));
    module.link_libc = true;
}

// Zig's bundled Darwin headers omit newer platform frameworks. The pinned
// Xcode package also supplies raylib's non-transitive framework paths.
fn addMacosSdkPaths(b: *std.Build, module: *std.Build.Module) void {
    const frameworks = b.lazyDependency("xcode_frameworks", .{}) orelse return;
    module.addSystemFrameworkPath(frameworks.path("Frameworks"));
    module.addSystemIncludePath(frameworks.path("include"));
    module.addLibraryPath(frameworks.path("lib"));
    module.link_libc = true;
}

// raylib-zig attaches Linux system libraries to raylib's static-library root.
// Zig 0.16 then archives the resolved .so files, which LLD rejects as
// non-relocatable archive members. Keep raylib static, but make those system
// libraries transitive dependencies of the Zig module instead.
fn moveRaylibLinuxLibraries(
    artifact: *std.Build.Step.Compile,
    module: *std.Build.Module,
) void {
    std.debug.assert(artifact.isStaticLibrary());
    var retained: usize = 0;
    for (artifact.root_module.link_objects.items) |object| switch (object) {
        .system_lib => |library| module.linkSystemLibrary(library.name, .{
            .needed = library.needed,
            .weak = library.weak,
            .use_pkg_config = library.use_pkg_config,
            .preferred_link_mode = library.preferred_link_mode,
            .search_strategy = library.search_strategy,
        }),
        else => {
            artifact.root_module.link_objects.items[retained] = object;
            retained += 1;
        },
    };
    artifact.root_module.link_objects.items.len = retained;
}
