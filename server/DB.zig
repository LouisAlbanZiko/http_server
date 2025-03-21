const std = @import("std");
const sqlite = @import("sqlite");

conn: sqlite.Connection,
last_user: UserID,
last_session: SessionID,

pub fn init(file_path: [:0]const u8) sqlite.Error!@This() {
    const conn = try sqlite.Connection.open(file_path);

    try conn.exec("CREATE TABLE IF NOT EXISTS user(id INTEGER PRIMARY KEY)");
    try conn.exec("CREATE TABLE IF NOT EXISTS session(token_hash BLOB PRIMARY KEY, user_id INTEGER NULL, expiry_s INTEGER NOT NULL, FOREIGN KEY(user_id) REFERENCES user(id))");

    return .{
        .conn = conn,
        .last_user = UserID{
            .timestamp_s = 0,
            .index = 0,
            .rand = 0,
        },
        .last_session = SessionID{
            .timestamp_s = 0,
            .index = 0,
            .rand = 0,
        },
    };
}

pub fn deinit(self: *@This()) void {
    self.conn.close();
}

pub const UserID = packed struct {
    timestamp_s: u40,
    index: u8,
    rand: u16,
    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.fmt.format(writer, "{d}:{d}:{X:0>4}", .{ self.timestamp_s, self.index, self.rand });
    }
};
pub fn new_user(self: *@This()) sqlite.Error!UserID {
    const now: u40 = @intCast(std.time.timestamp());
    if (now == self.last_user.timestamp_s) {
        self.last_user.index += 1;
    } else {
        self.last_user.index = 0;
        self.last_user.timestamp_s = now;
    }
    self.last_user.rand = std.crypto.random.int(u16);
    const user_id = self.last_user;

    var stmt = try self.conn.prepare_v2("INSERT INTO user(id) VALUES(?)");
    defer stmt.finalize();

    try stmt.bind_i64(0, @bitCast(user_id));

    _ = try stmt.step();

    return user_id;
}

pub const SessionID = packed struct {
    timestamp_s: u40,
    index: u8,
    rand: u16,
    pub fn format(
        self: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.fmt.format(writer, "{d}:{d}:{X:0>4}", .{ self.timestamp_s, self.index, self.rand });
    }
};
pub const SessionToken = [32]u8;
pub fn new_session(self: *@This(), max_age_s: i64, has_user: ?UserID) sqlite.Error!SessionToken {
    //var rand_bytes: [@typeInfo(SessionID).array.len / 2]u8 = undefined;
    //std.crypto.random.bytes(&rand_bytes);

    //const HEX_MAP: []const u8 = &[_]u8{
    //    '0', '1', '2', '3',
    //    '4', '5', '6', '7',
    //    '8', '9', 'A', 'B',
    //    'C', 'D', 'E', 'F',
    //};

    //var session_id: SessionID = undefined;
    //inline for (0..rand_bytes.len) |index| {
    //    session_id[index * 2 + 0] = HEX_MAP[rand_bytes[index] & 0xFF00 >> 4];
    //    session_id[index * 2 + 1] = HEX_MAP[rand_bytes[index] & 0x00FF >> 0];
    //}

    const now: u40 = @intCast(std.time.timestamp());
    if (now == self.last_session.timestamp_s) {
        self.last_session.index += 1;
    } else {
        self.last_session.timestamp_s = now;
        self.last_session.index = 0;
    }
    self.last_session.rand = std.crypto.random.int(u16);
    const session_id: SessionID = self.last_session;
    const session_id_bytes: [8]u8 = @bitCast(session_id);

    var session_token: SessionToken = undefined;
    std.mem.copyForwards(u8, session_token[0..8], &session_id_bytes);
    std.crypto.random.bytes(session_token[8..]);

    var session_token_hash: SessionToken = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(&session_token, &session_token_hash, .{});

    var stmt = try self.conn.prepare_v2("INSERT INTO session(token_hash, user_id, expiry_s) VALUES(?,?,?)");
    defer stmt.finalize();

    try stmt.bind_blob(0, &session_token_hash);
    if (has_user) |user_id| {
        try stmt.bind_i64(1, @bitCast(user_id));
    } else {
        try stmt.bind_null(1);
    }
    try stmt.bind_i64(2, now + max_age_s);

    _ = try stmt.step();

    return session_token;
}

pub const SessionCheck = enum { NotFound, Expired, Valid };
pub fn check_session_id(self: *@This(), session_token: SessionToken) sqlite.Error!SessionCheck {
    var session_token_hash: SessionToken = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(&session_token, &session_token_hash, .{});

    var stmt = try self.conn.prepare_v2("SELECT expiry_s FROM session WHERE token_hash = ?");
    defer stmt.finalize();

    try stmt.bind_blob(0, &session_token_hash);

    if (stmt.step() == .ROW) {
        const expiry_s = stmt.column_i64(0);
        if (std.time.timestamp() > expiry_s) {
            return .Expired;
        } else {
            return .Valid;
        }
    } else {
        return .NotFound;
    }
}

pub fn get_session_user(self: *@This(), session_token: SessionToken) sqlite.Error!?UserID {
    var session_token_hash: SessionToken = undefined;
    std.crypto.hash.sha3.Sha3_256.hash(&session_token, &session_token_hash, .{});

    var stmt = try self.conn.prepare_v2("SELECT user_id FROM session WHERE token_hash = ?");
    defer stmt.finalize();

    try stmt.bind_blob(0, &session_token_hash);

    if (try stmt.step() == .ROW) {
        if (stmt.column_type(0) == .INTEGER) {
            const user_id: UserID = @bitCast(stmt.column_i64(0));
            return user_id;
        } else {
            return null;
        }
    } else {
        return null;
    }
}
