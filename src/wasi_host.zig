const std = @import("std");
const waddle = @import("waddle");
const runtime = waddle.runtime;
const Runtime = runtime.Runtime;

// https://github.com/WebAssembly/WASI/blob/wasi-0.1/preview1/docs.md
// https://github.com/andrewrk/zig-wasi/blob/main/src/main.c
pub const WasiSnapshotPreview1 = struct {
    const wasi = std.os.wasi;
    const Preopen = struct {
        name: []const u8,
        wasi_fd: i32,
        host_fd: std.posix.fd_t,
    };

    const Prestat = wasi.prestat_t;
    const LookupFlags = wasi.lookupflags_t;
    const Rights = wasi.rights_t;
    const FdFlags = wasi.fdflags_t;
    const OFlags = wasi.oflags_t;

    allocator: std.mem.Allocator,
    preopen_dirs: []Preopen,
    vm_args: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, preopen_dir_paths: []const []const u8, vm_args: []const []const u8) !WasiSnapshotPreview1 {
        var preopens = try allocator.alloc(Preopen, preopen_dir_paths.len);
        errdefer allocator.free(preopens);

        for (preopen_dir_paths, 0..) |dir_path, i| {
            const host_dir = try std.fs.cwd().openDir(dir_path, .{});

            // Strip trailing slashes so WASI prefix matching is consistent whether
            // the user passes "/foo/bar" or "/foo/bar/".
            const name = std.mem.trimEnd(u8, dir_path, "/");

            // add 3 to skip over stdin, stdout, and stderr which are reserved for the first 3 WASI fds
            preopens[i] = .{ .name = name, .wasi_fd = @intCast(i + 3), .host_fd = host_dir.fd };
        }

        return .{
            .allocator = allocator,
            .preopen_dirs = preopens,
            .vm_args = vm_args,
        };
    }

    pub fn deinit(self: *WasiSnapshotPreview1) void {
        for (self.preopen_dirs) |preopen| {
            std.posix.close(preopen.host_fd);
        }

        self.allocator.free(self.preopen_dirs);
    }

    const ErrNo = enum(u16) {
        success = 0,
        badf = 8,
    };

    fn argsSizesGet(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const argc_ptr: usize = @intCast(args[0]);
        const argv_buf_size_ptr: usize = @intCast(args[1]);

        var total_buf_size: usize = 0;
        for (ctx.vm_args) |arg| {
            total_buf_size += arg.len + 1; // +1 for null terminator
        }

        try mem_inst.write(.i32, argc_ptr, @intCast(ctx.vm_args.len));
        try mem_inst.write(.i32, argv_buf_size_ptr, @intCast(total_buf_size));
        try pushErrNo(vm, .success);
    }

    fn argsGet(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const argv_ptr: usize = @intCast(args[0]);
        const argv_buf_ptr: usize = @intCast(args[1]);

        var buf_offset: usize = 0;
        for (ctx.vm_args, 0..) |arg, idx| {
            // Write pointer to this arg string into the argv array
            const str_ptr: u32 = @intCast(argv_buf_ptr + buf_offset);
            try mem_inst.write(.i32, argv_ptr + idx * 4, @bitCast(str_ptr));

            // Write the arg string bytes followed by a null terminator
            try mem_inst.writeBytes(argv_buf_ptr + buf_offset, arg);
            try mem_inst.writeBytes(argv_buf_ptr + buf_offset + arg.len, &.{0});

            buf_offset += arg.len + 1;
        }

        try pushErrNo(vm, .success);
    }

    fn pushErrNo(vm: *Runtime, errno: ErrNo) !void {
        try vm.stack.push(.i32, @intCast(@intFromEnum(errno)));
    }

    fn findPreopen(self: *WasiSnapshotPreview1, wasi_fd: i32) ?*Preopen {
        for (self.preopen_dirs) |*preopen| {
            if (preopen.wasi_fd == wasi_fd) {
                return preopen;
            }
        }

        return null;
    }

    fn wasiFdToHostFd(self: *WasiSnapshotPreview1, fd: i32) ?i32 {
        switch (fd) {
            0 => return std.posix.STDIN_FILENO,
            1 => return std.posix.STDOUT_FILENO,
            2 => return std.posix.STDERR_FILENO,
            else => {
                // Check if fd is one of the preopened directories
                for (self.preopen_dirs) |preopen| {
                    if (preopen.wasi_fd == fd) {
                        return preopen.host_fd;
                    }
                }

                // For files opened via path_open, the wasm fd IS the host fd
                // because pathOpen writes the raw host fd directly into wasm memory.
                if (fd > 0) return fd;
            },
        }

        return null;
    }

    fn fdRead(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 4);
        const wasi_fd: i32 = args[0];
        const iovs_ptr: usize = @intCast(args[1]);
        const iovs_len: usize = @intCast(args[2]);
        const nread: usize = @intCast(args[3]);
        var total_bytes_read: usize = 0;
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            for (0..iovs_len) |i| {
                const iov_ptr: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 0));
                const iov_len: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 4));
                const buffer = mem_inst.data[iov_ptr .. iov_ptr + iov_len];
                const bytes_read = try std.posix.read(host_fd, buffer);

                total_bytes_read += bytes_read;
                if (bytes_read < iov_len) {
                    break; // short read means EOF, stop processing further iovs
                }
            }

            try mem_inst.write(.i32, nread, @intCast(total_bytes_read));
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdWrite(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 4);
        const wasi_fd: i32 = args[0];
        const iovs_ptr: usize = @intCast(args[1]);
        const iovs_len: usize = @intCast(args[2]);
        const nwritten: usize = @intCast(args[3]);
        var total_bytes_written: usize = 0;
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            for (0..iovs_len) |i| {
                const iov_ptr: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 0));
                const iov_len: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 4));
                const bytes = mem_inst.data[iov_ptr .. iov_ptr + iov_len];
                const bytes_written = try std.posix.write(host_fd, bytes);

                total_bytes_written += bytes_written;
                if (bytes_written < iov_len) {
                    break; // short write, stop processing further iovs
                }
            }

            try mem_inst.write(.i32, nwritten, @intCast(total_bytes_written));
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdPrestatGet(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const wasi_fd: i32 = args[0];

        const prestat_ptr: usize = @intCast(args[1]);
        var errno: ErrNo = undefined;

        if (ctx.findPreopen(wasi_fd)) |preopen| {
            var prestat_bytes = [8]u8{ std.os.wasi.PREOPENTYPE_DIR, 0, 0, 0, 0, 0, 0, 0 };
            const name_len: u32 = @intCast(preopen.name.len);
            std.mem.writeInt(u32, prestat_bytes[4..8], name_len, .little);
            try mem_inst.writeBytes(prestat_ptr, &prestat_bytes);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdPrestatDirName(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 3);
        const wasi_fd: i32 = args[0];
        const path_ptr: usize = @intCast(args[1]);
        const path_len: usize = @intCast(args[2]);

        var errno: ErrNo = undefined;

        if (ctx.findPreopen(wasi_fd)) |preopen| {
            if (preopen.name.len != path_len) {
                return error.InvalidPathLenForWasiFdPrestatDirName;
            }

            const name_bytes = preopen.name[0..path_len];
            try mem_inst.writeBytes(path_ptr, name_bytes);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn pathOpen(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const opened_fd_ptr: usize = @intCast(try vm.stack.pop(.i32));
        const fdflags: FdFlags = @bitCast(@as(u16, @intCast(try vm.stack.pop(.i32))));
        _ = try vm.stack.pop(.i64); // fs_rights_inheriting (unused)
        const fs_rights_base: Rights = @bitCast(try vm.stack.pop(.i64));
        const oflags: OFlags = @bitCast(@as(u16, @intCast(try vm.stack.pop(.i32))));
        const path_len: usize = @intCast(try vm.stack.pop(.i32));
        const path_ptr: usize = @intCast(try vm.stack.pop(.i32));
        _ = try vm.stack.pop(.i32); // dirflags (unused)
        const wasi_dir_fd: i32 = try vm.stack.pop(.i32);
        var errno: ErrNo = undefined;
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];

        // TODO: Make this platform independent by using std.fs instead of std.os.posix
        if (ctx.wasiFdToHostFd(wasi_dir_fd)) |host_dir_fd| {
            var flags: std.posix.O = .{};
            if (oflags.CREAT) flags.CREAT = true;
            if (oflags.DIRECTORY) flags.DIRECTORY = true;
            if (oflags.EXCL) flags.EXCL = true;
            if (oflags.TRUNC) flags.TRUNC = true;
            if (fdflags.APPEND) flags.APPEND = true;
            if (fdflags.DSYNC) flags.DSYNC = true;
            if (fdflags.NONBLOCK) flags.NONBLOCK = true;
            if (fdflags.SYNC) flags.SYNC = true;

            if (fs_rights_base.FD_READ and fs_rights_base.FD_WRITE) {
                flags.ACCMODE = .RDWR;
            } else if (fs_rights_base.FD_WRITE) {
                flags.ACCMODE = .WRONLY;
            } // RDONLY is the default ACCMODE

            const mode: std.posix.mode_t = 0o644;
            const sub_path = mem_inst.data[path_ptr .. path_ptr + path_len];
            const res_fd = try std.posix.openat(host_dir_fd, sub_path, flags, mode);
            try mem_inst.write(.i32, opened_fd_ptr, @intCast(res_fd));
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdClose(vm: *Runtime) !void {
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const wasi_fd: i32 = try vm.stack.pop(.i32);
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            _ = std.posix.close(host_fd);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn procExit(vm: *Runtime) !void {
        const exit_code: u8 = @intCast(try vm.stack.pop(.i32));
        std.posix.exit(exit_code);
    }

    pub fn getImports() [9]runtime.Store.Import {
        const scope = "wasi_snapshot_preview1";

        return [_]runtime.Store.Import{
            .{
                .module = scope,
                .name = "fd_read",
                .value = .{ .func = fdRead },
            },
            .{
                .module = scope,
                .name = "fd_write",
                .value = .{ .func = fdWrite },
            },
            .{
                .module = scope,
                .name = "fd_prestat_get",
                .value = .{ .func = fdPrestatGet },
            },
            .{
                .module = scope,
                .name = "fd_prestat_dir_name",
                .value = .{ .func = fdPrestatDirName },
            },
            .{
                .module = scope,
                .name = "path_open",
                .value = .{ .func = pathOpen },
            },
            .{
                .module = scope,
                .name = "fd_close",
                .value = .{ .func = fdClose },
            },
            .{
                .module = scope,
                .name = "proc_exit",
                .value = .{ .func = procExit },
            },
            .{
                .module = scope,
                .name = "args_sizes_get",
                .value = .{ .func = argsSizesGet },
            },
            .{
                .module = scope,
                .name = "args_get",
                .value = .{ .func = argsGet },
            },
        };
    }
};
