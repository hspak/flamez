//! Build graph for the Flamez executable, its eBPF object, and the complete test root.

const std = @import("std");
const builtin = @import("builtin");
const dependencies = @import("root").dependencies;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui_prefix = b.option([]const u8, "gui-prefix", "Target SDL3, FreeType and libpng prefix (include/ and lib/)");
    const macos_sdk = b.option(
        []const u8,
        "macos-sdk",
        "macOS SDK root (native builds default to xcrun's selected SDK)",
    ) orelse if (target.result.os.tag == .macos and builtin.os.tag == .macos)
        std.mem.trim(u8, b.run(&.{
            "xcrun",
            "--sdk",
            "macosx",
            "--show-sdk-path",
        }), " \r\n\t")
    else
        null;
    const macos_libc = if (target.result.os.tag == .macos)
        macosLibcFile(b, macos_sdk)
    else
        null;

    const main_module = b.addModule("flamez", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
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
    const automation = b.option(bool, "automation", "Enable private Zrct GUI instrumentation") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "automation", automation);
    build_options.addOption(bool, "render_benchmark", b.option(
        bool,
        "render-benchmark",
        "Render 120 warmup and 600 measured frames without vsync or pacing, then exit",
    ) orelse false);
    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "ebpf", enable_ebpf);
    build_options.addOption(bool, "fps_counter", enable_fps_counter);
    build_options.addOption(bool, "perf_telemetry", enable_perf_telemetry);
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
    exe.setLibCFile(macos_libc);
    const app_modules = [_]*std.Build.Module{ main_module, exe.root_module };
    for (app_modules) |module| {
        module.addImport("zclay", zclay_dep.module("zclay"));
        module.link_libc = true;
        linkSdl(b, module, gui_prefix);
        if (gui_prefix) |prefix| {
            module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include/freetype2" }) });
            module.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
            module.linkSystemLibrary("png", .{ .use_pkg_config = .no });
        } else {
            module.linkSystemLibrary("freetype2", .{});
            module.linkSystemLibrary("libpng", .{});
        }
        module.addImport("footer_font", footer_font);
        module.addOptions("build_options", build_options);
        if (target.result.os.tag == .macos) addMacosSdkPaths(b, module, macos_sdk);
    }

    if (automation) {
        const zrct_dep = b.lazyDependency("zrct", .{}) orelse return;
        const zrct = ZrctBuild() orelse {
            b.getInstallStep().dependOn(&b.addFail("Automation requires the ../zrct checkout").step);
            return;
        };
        const driver = zrct.createModule(b, zrct_dep, .{
            .target = target,
            .optimize = optimize,
            .link_system_sdl = false,
        });
        linkSdl(b, driver, gui_prefix);
        for (app_modules) |module| module.addImport("zrct", driver);
        const gui_tests = zrct.addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/scenarios.py"),
            .executable = exe,
            .args = b.args orelse &.{},
        });
        b.step("test-zrct", "Run SDL GUI scenarios in an isolated desktop").dependOn(&gui_tests.step);
        const desktop_tests = zrct.addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/desktop.py"),
            .executable = exe,
            .desktop = true,
            .args = b.args orelse &.{},
        });
        b.step("test-zrct-desktop", "Test native Wayland input and display scale changes").dependOn(&desktop_tests.step);
        const benchmark = zrct.addRun(b, zrct_dep, .{
            .suite = b.path("tests/zrct/benchmarks.py"),
            .executable = exe,
            .benchmark = true,
            .args = b.args orelse &.{},
        });
        b.step("bench-zrct", "Measure SDL startup and idle-to-details latency (release builds)").dependOn(&benchmark.step);
    }
    if (target.result.os.tag == .macos) {
        addMacosProcessShim(b, main_module, true);
        addMacosProcessShim(b, exe.root_module, false);
        addMacosLiveTest(b, target, optimize, build_options, macos_sdk, macos_libc);
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
    main_tests.setLibCFile(macos_libc);
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_compile_step = b.step("test-compile", "Compile tests without running them");
    test_compile_step.dependOn(&main_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_main_tests.step);
}

fn ZrctBuild() ?type {
    // System-package builds can omit lazy dependencies entirely. Avoid an
    // unconditional @import (or lazyImport) requiring Zrct before options run.
    inline for (dependencies.root_deps) |dependency| {
        if (comptime std.mem.eql(u8, dependency[0], "zrct")) {
            const package = @field(dependencies.packages, dependency[1]);
            return if (@hasDecl(package, "build_zig")) package.build_zig else null;
        }
    }
    return null;
}

fn linkSdl(b: *std.Build, module: *std.Build.Module, prefix: ?[]const u8) void {
    if (prefix) |root| {
        module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
        module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib" }) });
        module.linkSystemLibrary("SDL3", .{ .use_pkg_config = .no });
    } else module.linkSystemLibrary("sdl3", .{});
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

fn addMacosProcessShim(b: *std.Build, module: *std.Build.Module, test_build: bool) void {
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

// Prefer the selected SDK for current API declarations. The package supplies
// framework paths for cross-builds that do not provide a complete SDK.
fn addMacosSdkPaths(b: *std.Build, module: *std.Build.Module, sdk: ?[]const u8) void {
    if (sdk) |root| {
        module.addSystemFrameworkPath(.{
            .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }),
        });
        module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });
        module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
        module.link_libc = true;
        return;
    }
    const frameworks = b.lazyDependency("xcode_frameworks", .{}) orelse return;
    module.addSystemFrameworkPath(frameworks.path("Frameworks"));
    module.addSystemIncludePath(frameworks.path("include"));
    module.addLibraryPath(frameworks.path("lib"));
    module.link_libc = true;
}

fn macosLibcFile(b: *std.Build, sdk: ?[]const u8) ?std.Build.LazyPath {
    const root = sdk orelse return null;
    // Merely adding -isystem leaves Zig's bundled Darwin headers ahead of the
    // SDK. Configure libc itself so Availability.h and the ES header agree,
    // while retaining system-header diagnostics for Apple's headers.
    const include = b.pathJoin(&.{ root, "usr/include" });
    return b.addWriteFiles().add("macos-sdk-libc.txt", b.fmt(
        "include_dir={s}\nsys_include_dir={s}\ncrt_dir=\n" ++
            "msvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n",
        .{ include, include },
    ));
}

fn addMacosLiveTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    sdk: ?[]const u8,
    libc_file: ?std.Build.LazyPath,
) void {
    const validator = b.addExecutable(.{
        .name = "macos-es-live-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macos_es_live_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validator.setLibCFile(libc_file);
    validator.root_module.addOptions("build_options", options);
    addMacosSdkPaths(b, validator.root_module, sdk);
    addMacosProcessShim(b, validator.root_module, false);
    const fixture = b.addExecutable(.{
        .name = "macos-es-fixture",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    fixture.setLibCFile(libc_file);
    addMacosSdkPaths(b, fixture.root_module, sdk);
    fixture.root_module.addCSourceFile(.{
        .file = b.path("src/macos_es_fixture.c"),
        .flags = &.{
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
        },
    });
    const step = b.step("macos-es-live-test", "Install the production ES validator and fixtures");
    step.dependOn(&b.addInstallArtifact(validator, .{}).step);
    step.dependOn(&b.addInstallArtifact(fixture, .{}).step);
    const script = b.addInstallFileWithDir(
        b.path("src/macos_es_fixture.sh"),
        .bin,
        "macos-es-fixture.sh",
    );
    step.dependOn(&script.step);
}
