const std = @import("std");
const waddle = @import("waddle");
const runtime = waddle.runtime;
const Runtime = runtime.Runtime;

// https://github.com/WebAssembly/WASI/blob/wasi-0.1/preview1/docs.md
// https://github.com/andrewrk/zig-wasi/blob/main/src/main.c
pub const WasiSnapshotPreview1 = struct {
    allocator: std.mem.Allocator,
    preopen_dirs: []Preopen,
    cli_args: []const []const u8,
    env_vars: []const []const u8, // in "KEY=VALUE" format

    const wasi = std.os.wasi;
    const Prestat = wasi.prestat_t;
    const LookupFlags = wasi.lookupflags_t;
    const Rights = wasi.rights_t;
    const FdFlags = wasi.fdflags_t;
    const OFlags = wasi.oflags_t;
    const Preopen = struct {
        name: []const u8,
        wasi_fd: i32,
        host_fd: std.posix.fd_t,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        preopen_dir_paths: []const []const u8,
        cli_args: []const []const u8,
        env_vars: []const []const u8,
    ) !WasiSnapshotPreview1 {
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
            .cli_args = cli_args,
            .env_vars = env_vars,
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
        noent = 44,
    };

    fn timespecToNs(ts: std.posix.timespec) u64 {
        if (ts.sec < 0) return 0;
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    fn posixModeToWasiFiletype(mode: std.posix.mode_t) u8 {
        const S = std.posix.S;
        return switch (mode & S.IFMT) {
            S.IFREG => 4, // REGULAR_FILE
            S.IFDIR => 3, // DIRECTORY
            S.IFCHR => 2, // CHARACTER_DEVICE
            S.IFBLK => 1, // BLOCK_DEVICE
            S.IFLNK => 7, // SYMBOLIC_LINK
            S.IFSOCK => 6, // SOCKET_STREAM
            else => 0, // UNKNOWN
        };
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

    fn argsSizesGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const argc_ptr: usize = @intCast(args[0]);
        const argv_buf_size_ptr: usize = @intCast(args[1]);

        var total_buf_size: usize = 0;
        for (ctx.cli_args) |arg| {
            total_buf_size += arg.len + 1; // +1 for null terminator
        }

        try mem_inst.write(.i32, argc_ptr, @intCast(ctx.cli_args.len));
        try mem_inst.write(.i32, argv_buf_size_ptr, @intCast(total_buf_size));
        try pushErrNo(vm, .success);
    }

    fn argsGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const argv_ptr: usize = @intCast(args[0]);
        const argv_buf_ptr: usize = @intCast(args[1]);
        var buf_offset: usize = 0;
        for (ctx.cli_args, 0..) |arg, idx| {
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

    fn environSizesGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const envc_ptr: usize = @intCast(args[0]);
        const env_buf_size_ptr: usize = @intCast(args[1]);

        var total_buf_size: usize = 0;
        for (ctx.env_vars) |env| {
            total_buf_size += env.len + 1; // +1 for null terminator
        }

        try mem_inst.write(.i32, envc_ptr, @intCast(ctx.env_vars.len));
        try mem_inst.write(.i32, env_buf_size_ptr, @intCast(total_buf_size));
        try pushErrNo(vm, .success);
    }

    fn environGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const envp_ptr: usize = @intCast(args[0]);
        const env_buf_ptr: usize = @intCast(args[1]);

        var buf_offset: usize = 0;
        for (ctx.env_vars, 0..) |env, idx| {
            // Write pointer to this env string into the envp array
            const str_ptr: u32 = @intCast(env_buf_ptr + buf_offset);
            try mem_inst.write(.i32, envp_ptr + idx * 4, @bitCast(str_ptr));

            // Write the env string bytes followed by a null terminator
            try mem_inst.writeBytes(env_buf_ptr + buf_offset, env);
            try mem_inst.writeBytes(env_buf_ptr + buf_offset + env.len, &.{0});

            buf_offset += env.len + 1;
        }

        try pushErrNo(vm, .success);
    }

    fn fdRead(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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
            // Track first iov so we can also write overflow bytes contiguously after it.
            // Some programs (e.g. wat2wasm) allocate a file_size-byte buffer but set
            // iov[0].len = file_size-1, expecting the last byte to end up at
            // iov[0].buf[file_size-1]. Writing overflow bytes contiguously handles this.
            var first_iov_ptr: u32 = 0;
            var first_iov_len: u32 = 0;

            for (0..iovs_len) |i| {
                const iov_ptr: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 0));
                const iov_len: u32 = @intCast(try mem_inst.read(.i32, iovs_ptr + i * 8 + 4));
                const buffer = mem_inst.data[iov_ptr .. iov_ptr + iov_len];
                const bytes_read = try std.posix.read(host_fd, buffer);

                if (i == 0) {
                    first_iov_ptr = iov_ptr;
                    first_iov_len = iov_len;
                } else if (bytes_read > 0 and first_iov_ptr != 0) {
                    // Also write overflow bytes contiguously after iov[0]'s data so that
                    // callers treating iov[0].buf as a file_size-byte contiguous buffer work.
                    const contiguous_dest = first_iov_ptr + first_iov_len + (total_bytes_read - first_iov_len);
                    @memcpy(mem_inst.data[contiguous_dest .. contiguous_dest + bytes_read], buffer[0..bytes_read]);
                }

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

    fn fdWrite(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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

    fn fdSeek(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        // sig: (fd i32, offset i64, whence i32, newoffset_ptr i32) -> i32
        const new_offset_ptr: usize = @intCast(try vm.stack.pop(.i32));
        const whence: i32 = try vm.stack.pop(.i32);
        const offset: i64 = try vm.stack.pop(.i64);
        const wasi_fd: i32 = try vm.stack.pop(.i32);
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            const new_offset = std.posix.system.lseek(host_fd, offset, @intCast(whence));
            try mem_inst.write(.i64, new_offset_ptr, @intCast(new_offset));
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdStatGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const wasi_fd: i32 = args[0];
        const stat_buf_ptr: usize = @intCast(args[1]);
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            const fstat = try std.posix.fstat(host_fd);
            var stat_buf_bytes = [_]u8{0} ** 24;
            // fdstat layout: filetype(u8) + pad(1) + fdflags(u16) + pad(4) + rights_base(u64) + rights_inheriting(u64)
            stat_buf_bytes[0] = posixModeToWasiFiletype(fstat.mode);
            std.mem.writeInt(u16, stat_buf_bytes[2..4], 0, .little); // fdflags
            std.mem.writeInt(u64, stat_buf_bytes[8..16], 0xFFFFFFFFFFFFFFFF, .little); // rights_base
            std.mem.writeInt(u64, stat_buf_bytes[16..24], 0, .little); // rights_inheriting
            try mem_inst.writeBytes(stat_buf_ptr, &stat_buf_bytes);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdFdstatGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 2);
        const wasi_fd: i32 = args[0];
        const stat_ptr: usize = @intCast(args[1]);
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            const fstat = try std.posix.fstat(host_fd);
            var stat_bytes = [_]u8{0} ** 24;
            // fdstat layout: filetype(u8) + pad(1) + fdflags(u16) + pad(4) + rights_base(u64) + rights_inheriting(u64)
            stat_bytes[0] = posixModeToWasiFiletype(fstat.mode);
            const raw_flags = std.posix.fcntl(host_fd, std.posix.F.GETFL, 0) catch 0;
            const o_flags: std.posix.O = @bitCast(@as(u32, @truncate(raw_flags)));
            var fdflags: FdFlags = .{};
            fdflags.APPEND = o_flags.APPEND;
            fdflags.DSYNC = o_flags.DSYNC;
            fdflags.NONBLOCK = o_flags.NONBLOCK;
            fdflags.SYNC = o_flags.SYNC;
            std.mem.writeInt(u16, stat_bytes[2..4], @as(u16, @bitCast(fdflags)), .little);
            std.mem.writeInt(u64, stat_bytes[8..16], 0xFFFFFFFFFFFFFFFF, .little); // rights_base
            std.mem.writeInt(u64, stat_bytes[16..24], 0xFFFFFFFFFFFFFFFF, .little); // rights_inheriting
            try mem_inst.writeBytes(stat_ptr, &stat_bytes);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdFdstatSetFlags(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const args = vm.stack.staticPopValues(.i32, 2);
        const wasi_fd: i32 = args[0];
        const fdflags: FdFlags = @bitCast(@as(u16, @intCast(args[1])));
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_fd| {
            // Get current flags to preserve access mode bits, then apply the WASI-controlled ones.
            const current = std.posix.fcntl(host_fd, std.posix.F.GETFL, 0) catch 0;
            var o_flags: std.posix.O = @bitCast(@as(u32, @truncate(current)));
            o_flags.APPEND = fdflags.APPEND;
            o_flags.DSYNC = fdflags.DSYNC;
            o_flags.NONBLOCK = fdflags.NONBLOCK;
            o_flags.SYNC = fdflags.SYNC;
            _ = std.posix.fcntl(host_fd, std.posix.F.SETFL, @as(usize, @as(u32, @bitCast(o_flags)))) catch {};
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn pathFilestatGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const ctx = try vm.store.getContext(WasiSnapshotPreview1);
        const mem_inst = &vm.store.mems.items[vm.module.mem_addrs[0]];
        const args = vm.stack.staticPopValues(.i32, 5);
        const wasi_fd: i32 = args[0];
        const lookup_flags: u32 = @intCast(args[1]);
        const path_ptr: usize = @intCast(args[2]);
        const path_len: usize = @intCast(args[3]);
        const filestat_ptr: usize = @intCast(args[4]);
        var errno: ErrNo = undefined;

        if (ctx.wasiFdToHostFd(wasi_fd)) |host_dir_fd| {
            const sub_path = mem_inst.data[path_ptr .. path_ptr + path_len];
            // WASI lookupflags bit 0 = SYMLINK_FOLLOW; AT_SYMLINK_NOFOLLOW when NOT set
            const at_flags: u32 = if (lookup_flags & 1 == 0) std.posix.AT.SYMLINK_NOFOLLOW else 0;
            const stat = std.posix.fstatat(host_dir_fd, sub_path, at_flags) catch {
                errno = .noent;
                try pushErrNo(vm, errno);
                return;
            };
            // filestat layout (64 bytes):
            //   offset  0: dev      (u64)
            //   offset  8: ino      (u64)
            //   offset 16: filetype (u8)  + 7 bytes padding
            //   offset 24: nlink    (u64)
            //   offset 32: size     (u64)
            //   offset 40: atim     (u64, nanoseconds)
            //   offset 48: mtim     (u64, nanoseconds)
            //   offset 56: ctim     (u64, nanoseconds)
            var filestat_bytes = [_]u8{0} ** 64;
            std.mem.writeInt(u64, filestat_bytes[0..8], @as(u64, @intCast(stat.dev)), .little);
            std.mem.writeInt(u64, filestat_bytes[8..16], stat.ino, .little);
            filestat_bytes[16] = posixModeToWasiFiletype(stat.mode);
            std.mem.writeInt(u64, filestat_bytes[24..32], @as(u64, @intCast(stat.nlink)), .little);
            std.mem.writeInt(u64, filestat_bytes[32..40], @as(u64, @bitCast(@as(i64, stat.size))), .little);
            const atim_ns = timespecToNs(stat.atime());
            const mtim_ns = timespecToNs(stat.mtime());
            const ctim_ns = timespecToNs(stat.ctime());
            std.mem.writeInt(u64, filestat_bytes[40..48], atim_ns, .little);
            std.mem.writeInt(u64, filestat_bytes[48..56], mtim_ns, .little);
            std.mem.writeInt(u64, filestat_bytes[56..64], ctim_ns, .little);
            try mem_inst.writeBytes(filestat_ptr, &filestat_bytes);
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdPrestatGet(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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

    fn fdPrestatDirName(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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

    fn pathOpen(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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
            const res_fd = std.posix.openat(host_dir_fd, sub_path, flags, mode) catch {
                errno = .noent;
                try pushErrNo(vm, errno);
                return;
            };
            try mem_inst.write(.i32, opened_fd_ptr, @intCast(res_fd));
            errno = .success;
        } else {
            errno = .badf;
        }

        try pushErrNo(vm, errno);
    }

    fn fdClose(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
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

    fn procExit(ctx_ptr: *anyopaque) !void {
        const vm: *Runtime = @ptrCast(@alignCast(ctx_ptr));
        const exit_code: u8 = @intCast(try vm.stack.pop(.i32));
        std.posix.exit(exit_code);
    }

    pub fn getImports() [16]runtime.Store.Import {
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
                .name = "fd_seek",
                .value = .{ .func = fdSeek },
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
                .name = "fd_stat_get",
                .value = .{ .func = fdStatGet },
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
            .{
                .module = scope,
                .name = "environ_sizes_get",
                .value = .{ .func = environSizesGet },
            },
            .{
                .module = scope,
                .name = "environ_get",
                .value = .{ .func = environGet },
            },
            .{
                .module = scope,
                .name = "fd_fdstat_get",
                .value = .{ .func = fdFdstatGet },
            },
            .{
                .module = scope,
                .name = "fd_fdstat_set_flags",
                .value = .{ .func = fdFdstatSetFlags },
            },
            .{
                .module = scope,
                .name = "path_filestat_get",
                .value = .{ .func = pathFilestatGet },
            },
        };
    }
};
