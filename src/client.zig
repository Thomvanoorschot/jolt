const std = @import("std");
const xev = @import("xev");
const tcp = @import("tcp.zig");
const wss = @import("client_wss.zig");
const core_types = @import("core_types.zig");

const QueuedWrite = core_types.QueuedWrite;
const ConnectionState = core_types.ConnectionState;

const ClientConfig = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub const Client = struct {
    loop: *xev.Loop,
    socket: xev.TCP,
    allocator: std.mem.Allocator,
    config: ClientConfig,
    address: std.net.Address,

    connect_completion: xev.Completion = undefined,
    read_completion: xev.Completion = undefined,
    close_completion: xev.Completion = undefined,
    ping_completion: xev.Completion = undefined,

    connection_state: ConnectionState = .initial,
    read_buf: [1024]u8 = undefined,

    write_queue: xev.WriteQueue,
    queued_write_pool: std.heap.MemoryPool(QueuedWrite),

    callback_context: *anyopaque,
    read_callback: *const fn (
        context: *anyopaque,
        payload: []const u8,
    ) anyerror!void,

    pending_websocket_writes: std.ArrayList([]const u8),
    incomplete_frame_buffer: []u8 = &[_]u8{},

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        config: ClientConfig,
        comptime read_callback: *const fn (
            context: *anyopaque,
            payload: []const u8,
        ) anyerror!void,
        callback_context: *anyopaque,
    ) !Client {
        const address = try std.net.Address.parseIp4(config.host, config.port);
        return .{
            .allocator = allocator,
            .loop = loop,
            .address = address,
            .socket = try xev.TCP.init(address),
            .config = config,

            .read_callback = read_callback,
            .callback_context = callback_context,

            .write_queue = xev.WriteQueue{},
            .queued_write_pool = std.heap.MemoryPool(QueuedWrite).init(allocator),

            .pending_websocket_writes = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(client: *Client) void {
        tcp.closeSocket(client);
    }
    pub fn deinitMemory(client: *Client) void {
        for (client.pending_websocket_writes.items) |item| {
            client.allocator.free(item);
        }
        client.pending_websocket_writes.deinit();
        client.allocator.free(client.incomplete_frame_buffer);
        client.queued_write_pool.deinit();
    }

    pub fn connect(client: *Client) !void {
        tcp.connect(
            client,
            client.loop,
            &client.connect_completion,
            client.address,
        );
    }

    pub fn read(client: *Client) !void {
        wss.read(client);
    }

    pub fn write(client: *Client, data: []const u8) !void {
        try wss.write(client, data, .text);
    }
};

test "create client" {
    std.testing.log_level = .info;
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const wrapperStruct = struct {
        const Self = @This();
        fn read_callback(context: *anyopaque, payload: []const u8) !void {
            // You can access the context by casting it to the correct type
            // const self = @as(*Self, @ptrCast(context));
            // self.read_callback(self.callback_context, payload);
            std.log.info("read_callback: {s}\n", .{payload});
            _ = context;
        }
    };
    var ws = wrapperStruct{};

    var client = try Client.init(
        std.testing.allocator,
        &loop,
        .{
            .host = "127.0.0.1",
            .port = 8080,
            .path = "/ws",
        },
        wrapperStruct.read_callback,
        @ptrCast(&ws),
    );
    try client.connect();

    const start_time = std.time.milliTimestamp();
    const duration_ms = 1000;

    while (std.time.milliTimestamp() - start_time < duration_ms) {
        try loop.run(.once);
    }
    client.deinit();
    while (client.connection_state != .closed) {
        try loop.run(.once);
    }
}
