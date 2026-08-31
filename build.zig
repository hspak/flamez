//! Build graph for the Flamez executable, its eBPF object, and both test roots.

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
            // Avoid an X11 fallback so development runs use the active Wayland session.
            .linux_display_backend = .Wayland,
        })
    else
        b.dependency("raylib_zig", .{
            .target = target,
            .optimize = optimize,
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
    const footer_font_source = footer_font_files.add(
        "footer_font.zig",
        "pub const ttf = @embedFile(\"RobotoMono-Medium.ttf\");\n",
    );
    _ = footer_font_files.addCopyFile(
        b.path(
            "zig-pkg/N-V-__8AALPgZwA7tLqRlkCCL7OrkEhj4xZ3y_0FxgR42t0W/" ++
                "examples/raylib-multi-context/resources/RobotoMono-Medium.ttf",
        ),
        "RobotoMono-Medium.ttf",
    );
    const footer_font = b.createModule(.{ .root_source_file = footer_font_source });

    main_module.addImport("zclay", zclay_dep.module("zclay"));
    main_module.addImport("raylib", raylib);
    main_module.addImport("footer_font", footer_font);
    main_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "flamez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zclay", zclay_dep.module("zclay"));
    exe.root_module.addImport("raylib", raylib);
    exe.root_module.addImport("footer_font", footer_font);
    exe.root_module.addOptions("build_options", build_options);
    if (target.result.os.tag == .macos) {
        addMacosSdkPaths(b, main_module);
        addMacosSdkPaths(b, exe.root_module);
        addMacosProcessShim(b, main_module, true);
        addMacosProcessShim(b, exe.root_module, false);
    }

    var bpf_object: ?std.Build.LazyPath = null;
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
        bpf_object = bpf_compile.addOutputFileArg("flamez.bpf.o");
        const install_bpf = b.addInstallFile(bpf_object.?, "share/flamez/flamez.bpf.o");
        b.getInstallStep().dependOn(&install_bpf.step);

        exe.root_module.addCSourceFile(.{
            .file = b.path("src/ebpf_shim.c"),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
            },
        });
        exe.root_module.linkSystemLibrary("bpf", .{});
        exe.root_module.link_libc = true;

        // Tests reached from main can instantiate tracer declarations through
        // shared process-info helpers, so this root needs the same bridge.
        main_module.addCSourceFile(.{
            .file = b.path("src/ebpf_shim.c"),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
            },
        });
        main_module.linkSystemLibrary("bpf", .{});
        main_module.link_libc = true;
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    // Run from the installation tree so the BPF object layout matches production.
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Zig collects tests from one root source, so main and tracer need separate artifacts.
    const main_tests = b.addTest(.{
        .root_module = main_module,
        .filters = test_filters,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const tracer_options = b.addOptions();
    tracer_options.addOption(bool, "ebpf", enable_ebpf);
    tracer_options.addOption(bool, "fps_counter", enable_fps_counter);
    tracer_options.addOption(bool, "perf_telemetry", enable_perf_telemetry);
    tracer_options.addOption(bool, "msaa", enable_msaa);
    tracer_options.addOption(
        bool,
        "macos_require_endpoint_security",
        require_macos_endpoint_security,
    );
    if (bpf_object) |path| {
        tracer_options.addOptionPath("bpf_object", path);
    } else {
        tracer_options.addOption([]const u8, "bpf_object", "");
    }

    const tracer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tracer.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    tracer_tests.root_module.addOptions("build_options", tracer_options);
    if (target.result.os.tag == .macos) {
        addMacosSdkPaths(b, tracer_tests.root_module);
        addMacosProcessShim(b, tracer_tests.root_module, true);
    }
    if (enable_ebpf) {
        tracer_tests.root_module.addCSourceFile(.{
            .file = b.path("src/ebpf_shim.c"),
            .flags = &.{
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
            },
        });
        tracer_tests.root_module.linkSystemLibrary("bpf", .{});
        tracer_tests.root_module.link_libc = true;
    }
    const run_tracer_tests = b.addRunArtifact(tracer_tests);

    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&main_tests.step);
    test_compile_step.dependOn(&tracer_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_tracer_tests.step);
}

fn addMacosProcessShim(
    b: *std.Build,
    module: *std.Build.Module,
    test_build: bool,
) void {
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
