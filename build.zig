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
    // Revisit when Zig gains .sframe support: if `zig build -Dtarget=native`
    // links cleanly, this default and the system paths below can all go.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});

    // In 0.16 linking is configured on the module, not the Compile step.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // libetpan provides IMAP and MIME parsing in C, which is the bulk of what
    // Python's imaplib + email modules were doing for us. @cImport means there
    // is no binding layer to maintain -- the header is imported directly.
    // Built with an explicit glibc target rather than `native`, because Zig
    // 0.16's linker rejects the .sframe relocations this host's GCC 16 emits
    // into crt1.o. An explicit target makes Zig use its own start files.
    // The cost is that it no longer searches system paths, so they are named
    // here.
    root.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    root.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    root.linkSystemLibrary("etpan", .{});

    // Zig's translate-c cannot represent C bitfields, so libetpan structs
    // containing one (mailimap_selection_info) come through as opaque. This
    // shim lets the C compiler read those fields and hands them back as
    // plain functions. Zig compiles it as part of the same build.
    root.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-std=c11"} });

    const exe = b.addExecutable(.{
        .name = "ronny",
        .root_module = root,
        // Zig 0.16's self-hosted ELF linker rejects the .sframe relocations
        // that this host's GCC 16 emits into crt1.o
        // ("unhandled relocation type R_X86_64_PC64"). LLD handles them, and
        // we need the system C runtime because we link libetpan.
        // (linker left to default; the target choice is what matters -- see below)
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Connect to the mailbox and print the latest message");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
