const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to an explicit glibc triple rather than `native`.
    //
    // Zig 0.16's ELF linker cannot handle the .sframe relocations that this
    // host's GCC 16.2.1 emits into crt1.o ("unhandled relocation type
    // R_X86_64_PC64"), and -flld crashes the compiler. A hello-world with
    // -lc fails the same way, so this is a toolchain disagreement, not
    // anything about this project. Naming the target explicitly makes Zig
    // use its own bundled start files instead of the system's.
    //
    // The cost is that an explicit target stops Zig searching system paths,
    // so those are named below.
    //
    // Revisit when Zig gains .sframe support: if `zig build -Dtarget=native`
    // links cleanly, this default and the explicit paths can all go.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});

    // libetpan gives us IMAP and MIME parsing in C, which is the bulk of what
    // Python's imaplib and email modules were doing.
    //
    // 0.16 deprecates @cImport in favour of translating through the build
    // system, which makes it a proper cacheable step rather than work redone
    // inside every compilation. src/c.h is the input; Zig code imports the
    // result as @import("c").
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });

    // In 0.16 linking is configured on the module, not the Compile step.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });

    root.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    root.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    root.linkSystemLibrary("etpan", .{});

    // translate-c has no representation for C bitfields, so libetpan structs
    // containing one (mailimap_selection_info) arrive opaque and their fields
    // are unreachable. This shim reads them from C, and also walks libetpan's
    // nested result structures, handing Zig flat data.
    root.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-std=gnu11"} });

    // whisper.cpp for voice notes. Same reasoning as the libetpan shim:
    // whisper_full_params is a large struct with nested unions, so it is
    // assembled in C and exposed as one flat call.
    // ggml must be linked explicitly alongside whisper: it is what registers
    // the compute backends, and without it whisper aborts at model load with
    // GGML_ASSERT(device) failed. whisper-cli links all three the same way.
    root.linkSystemLibrary("whisper", .{});
    root.linkSystemLibrary("ggml", .{});
    root.linkSystemLibrary("ggml-base", .{});
    root.addCSourceFile(.{ .file = b.path("src/whisper_shim.c"), .flags = &.{"-std=gnu11"} });

    const exe = b.addExecutable(.{
        .name = "ronny",
        .root_module = root,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Watch the mailbox");
    run_step.dependOn(&run_cmd.step);

    // A scratch target for exercising one piece against the real mailbox.
    // Ad-hoc `zig build-exe` cannot be used any more: the translated C module
    // only exists inside the build graph, so probes have to share it.
    const probe_source = b.path("src/probe.zig");
    {
        const probe = b.addExecutable(.{
            .name = "probe",
            .root_module = b.createModule(.{
                .root_source_file = probe_source,
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
            }),
        });
        probe.root_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        probe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        probe.root_module.linkSystemLibrary("etpan", .{});
        probe.root_module.linkSystemLibrary("whisper", .{});
        probe.root_module.linkSystemLibrary("ggml", .{});
        probe.root_module.linkSystemLibrary("ggml-base", .{});
        probe.root_module.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-std=gnu11"} });
        probe.root_module.addCSourceFile(.{ .file = b.path("src/whisper_shim.c"), .flags = &.{"-std=gnu11"} });

        const probe_run = b.addRunArtifact(probe);
        if (b.args) |args| probe_run.addArgs(args);
        b.step("probe", "Run src/probe.zig against the real mailbox").dependOn(&probe_run.step);
    }

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
