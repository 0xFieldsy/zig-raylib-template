//! Falling-block rules, independent of the window and rendering.
const std = @import("std");

pub const width = 10;
pub const height = 24;
pub const hidden = 4;

pub const Kind = enum(u8) { i, o, t, s, z, j, l };
pub const Point = struct { x: i32, y: i32 };
pub const Piece = struct { kind: Kind, rotation: u2 = 0, x: i32 = 3, y: i32 = 3 };

const Kick = [5]Point;

const bases = [7][4]Point{
    .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 } },
    .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
    .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
    .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } },
    .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
    .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
    .{ .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
};

pub fn cells(piece: Piece) [4]Point {
    var result = bases[@intFromEnum(piece.kind)];
    for (&result) |*p| {
        if (piece.kind != .o) for (0..piece.rotation) |_| {
            const old_x = p.x;
            p.x = (if (piece.kind == .i) @as(i32, 3) else 2) - p.y;
            p.y = old_x;
        };
        p.x += piece.x;
        p.y += piece.y;
    }
    return result;
}

fn kicks(kind: Kind, from: u2, to: u2) Kick {
    // SRS offsets use upward-positive Y; convert when applying them.
    const a: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = -1, .y = 1 },
        .{ .x = 0, .y = -2 },
        .{ .x = -1, .y = -2 },
    };
    const b: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = -1 },
        .{ .x = 0, .y = 2 },
        .{ .x = 1, .y = 2 },
    };
    const c: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = -2 },
        .{ .x = 1, .y = -2 },
    };
    const d: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = -1, .y = -1 },
        .{ .x = 0, .y = 2 },
        .{ .x = -1, .y = 2 },
    };

    const ia: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = -2, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = -2, .y = -1 },
        .{ .x = 1, .y = 2 },
    };
    const ib: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = -1, .y = -2 },
    };
    const ic: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = -1, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = -1, .y = 2 },
        .{ .x = 2, .y = -1 },
    };
    const id: Kick = .{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = -2, .y = 0 },
        .{ .x = 1, .y = -2 },
        .{ .x = -2, .y = 1 },
    };

    if (kind != .i) return switch (from) {
        0, 2 => if (to == 1) a else c,
        1 => b,
        3 => d,
    };

    return switch (from) {
        0 => if (to == 1) ia else ic,
        1 => if (to == 0) ib else ic,
        2 => if (to == 1) id else ib,
        3 => if (to == 2) ia else id,
    };
}

pub const Game = struct {
    board: [height][width]u8 = @splat(@splat(0)),
    active: Piece = .{ .kind = .i },
    queue: [5]Kind = undefined,
    bag: [7]Kind = undefined,
    bag_index: usize = 7,
    prng: std.Random.DefaultPrng,
    held: ?Kind = null,
    hold_used: bool = false,
    over: bool = false,
    score: u64 = 0,
    lines: u32 = 0,
    combo: i32 = -1,
    back_to_back: bool = false,
    gravity_timer: f32 = 0,
    lock_timer: f32 = 0,
    lock_resets: u8 = 0,
    rotated: bool = false,
    kick_index: usize = 0,
    event: [:0]const u8 = "READY",
    event_time: f32 = 0,
    clear_mask: u32 = 0,
    clear_time: f32 = 0,
    locks: u32 = 0,

    pub fn init(seed: u64) Game {
        var g: Game = .{ .prng = .init(seed) };
        for (&g.queue) |*k| k.* = g.next();
        g.spawnQueue();
        return g;
    }

    fn next(g: *Game) Kind {
        if (g.bag_index == 7) {
            g.bag = .{ .i, .o, .t, .s, .z, .j, .l };
            g.prng.random().shuffle(Kind, &g.bag);
            g.bag_index = 0;
        }
        const k = g.bag[g.bag_index];
        g.bag_index += 1;
        return k;
    }

    fn spawn(g: *Game, kind: Kind) void {
        g.active = .{ .kind = kind };
        g.gravity_timer = 0;
        g.lock_timer = 0;
        g.lock_resets = 0;
        g.rotated = false;
        if (!g.fits(g.active)) g.over = true;
    }

    fn spawnQueue(g: *Game) void {
        const kind = g.queue[0];
        for (0..4) |i| g.queue[i] = g.queue[i + 1];
        g.queue[4] = g.next();
        g.spawn(kind);
    }

    pub fn level(g: *const Game) u32 {
        return g.lines / 10 + 1;
    }

    pub fn fits(g: *const Game, piece: Piece) bool {
        for (cells(piece)) |p| {
            if (p.x < 0 or p.x >= width or p.y < 0 or p.y >= height) return false;
            if (g.board[@intCast(p.y)][@intCast(p.x)] != 0) return false;
        }
        return true;
    }

    pub fn grounded(g: *const Game) bool {
        var p = g.active;
        p.y += 1;
        return !g.fits(p);
    }

    fn resetLock(g: *Game, was_grounded: bool) void {
        if (was_grounded and g.lock_resets < 15) {
            g.lock_timer = 0;
            g.lock_resets += 1;
        }
    }

    pub fn move(g: *Game, dx: i32) bool {
        if (g.over) return false;
        var p = g.active;
        p.x += dx;
        if (!g.fits(p)) return false;
        const ground = g.grounded();
        g.active = p;
        g.rotated = false;
        g.resetLock(ground);
        return true;
    }

    pub fn rotate(g: *Game, clockwise: bool) bool {
        if (g.over) return false;
        if (g.active.kind == .o) {
            g.resetLock(g.grounded());
            return true;
        }
        var p = g.active;
        p.rotation +%= if (clockwise) @as(u2, 1) else 3;
        for (kicks(p.kind, g.active.rotation, p.rotation), 0..) |offset, i| {
            var candidate = p;
            candidate.x += offset.x;
            candidate.y -= offset.y;
            if (g.fits(candidate)) {
                const ground = g.grounded();
                g.active = candidate;
                g.rotated = true;
                g.kick_index = i;
                g.resetLock(ground);
                return true;
            }
        }
        return false;
    }

    pub fn hold(g: *Game) void {
        if (g.over or g.hold_used) return;
        const kind = g.active.kind;
        if (g.held) |k| g.spawn(k) else g.spawnQueue();
        g.held = kind;
        g.hold_used = true;
    }

    pub fn ghost(g: *const Game) Piece {
        var p = g.active;
        while (true) {
            var candidate = p;
            candidate.y += 1;
            if (!g.fits(candidate)) return p;
            p = candidate;
        }
    }

    pub fn hardDrop(g: *Game) void {
        if (g.over) return;
        const p = g.ghost();
        g.score += @as(u64, @intCast(p.y - g.active.y)) * 2;
        g.active = p;
        g.lock();
    }

    pub fn tick(g: *Game, dt: f32, soft: bool) void {
        if (g.over) return;
        g.event_time = @max(0, g.event_time - dt);
        g.clear_time = @max(0, g.clear_time - dt);
        const gravity = @max(
            0.00001,
            std.math.pow(
                f32,
                @max(0.05, 0.8 - @as(f32, @floatFromInt(g.level() - 1)) * 0.007),
                @floatFromInt(g.level() - 1),
            ),
        );
        const interval = if (soft) @min(gravity, 0.035) else gravity;

        // Time banked under slower gravity would otherwise drop many rows at once.
        g.gravity_timer = @min(g.gravity_timer, interval) + dt;
        while (g.gravity_timer >= interval) {
            g.gravity_timer -= interval;
            var p = g.active;
            p.y += 1;
            if (!g.fits(p)) break;
            g.active = p;
            if (soft) {
                g.score += 1;
                g.rotated = false;
            }
        }
        if (g.grounded()) {
            g.lock_timer += dt;
            if (g.lock_timer >= 0.5) g.lock();
        } else if (g.lock_resets < 15) g.lock_timer = 0;
    }

    fn occupied(g: *const Game, x: i32, y: i32) bool {
        return x < 0 or x >= width or y < 0 or y >= height or g.board[@intCast(y)][@intCast(x)] != 0;
    }

    fn spin(g: *const Game) u2 {
        if (g.active.kind != .t or !g.rotated) return 0;
        const x = g.active.x;
        const y = g.active.y;
        const corners = [4]bool{
            g.occupied(x, y),
            g.occupied(x + 2, y),
            g.occupied(x + 2, y + 2),
            g.occupied(x, y + 2),
        };
        var count: u8 = 0;
        for (corners) |v| {
            if (v) count += 1;
        }
        if (count < 3) return 0;
        const r: usize = g.active.rotation;
        return if ((corners[r] and corners[(r + 1) % 4]) or g.kick_index == 4) 2 else 1;
    }

    pub fn clearRows(g: *Game) u32 {
        var write: usize = height;
        var cleared: u32 = 0;
        var mask: u32 = 0;
        var read: usize = height;
        while (read > 0) {
            read -= 1;
            var full = true;
            for (g.board[read]) |v| {
                if (v == 0) full = false;
            }
            if (full) {
                cleared += 1;
                mask |= @as(u32, 1) << @intCast(read);
            } else {
                write -= 1;
                g.board[write] = g.board[read];
            }
        }
        for (g.board[0..write]) |*row| row.* = @splat(0);
        if (cleared > 0) {
            g.clear_mask = mask;
            g.clear_time = 0.2;
        }
        return cleared;
    }

    fn lock(g: *Game) void {
        g.locks += 1;
        const tspin = g.spin();
        var visible = false;
        for (cells(g.active)) |p| {
            g.board[@intCast(p.y)][@intCast(p.x)] = @intFromEnum(g.active.kind) + 1;
            if (p.y >= hidden) visible = true;
        }
        const n = g.clearRows();
        const multiplier: u64 = g.level();
        const ordinary = [_]u64{ 0, 100, 300, 500, 800 };
        const full_spin = [_]u64{ 400, 800, 1200, 1600 };
        const mini_spin = [_]u64{ 100, 200, 400, 1600 };
        var points = if (tspin == 2) full_spin[@min(n, 3)] else if (tspin == 1) mini_spin[@min(n, 3)] else ordinary[n];
        const previous_back_to_back = g.back_to_back;
        const difficult = n > 0 and (n == 4 or tspin > 0);
        if (difficult and g.back_to_back) points = points * 3 / 2;
        if (n > 0) {
            g.combo += 1;
            points += @as(u64, @intCast(g.combo)) * 50;
            g.back_to_back = difficult;
        } else g.combo = -1;
        g.score += points * multiplier;
        g.lines += n;
        g.event = if (tspin == 2) "T-SPIN" else if (tspin == 1) "T-SPIN MINI" else switch (n) {
            1 => "SINGLE",
            2 => "DOUBLE",
            3 => "TRIPLE",
            4 => "ZETRIS",
            else => "",
        };
        if (n > 0) {
            var empty = true;
            for (g.board) |row| for (row) |v| {
                if (v != 0) {
                    empty = false;
                }
            };
            if (empty) {
                g.score += (if (n == 4 and previous_back_to_back) @as(u64, 3200) else ([_]u64{ 0, 800, 1200, 1800, 2000 })[n]) * multiplier;
                g.event = "PERFECT CLEAR";
            }
        }
        g.event_time = 2;
        if (!visible) {
            g.over = true;
            return;
        }
        g.hold_used = false;
        g.spawnQueue();
    }
};

test "seven-bag contains every piece once" {
    var g: Game = .{ .prng = .init(42) };
    for (0..20) |_| {
        var seen: [7]bool = @splat(false);
        for (0..7) |_| {
            const k = @intFromEnum(g.next());
            try std.testing.expect(!seen[k]);
            seen[k] = true;
        }
    }
}

test "I piece kicks away from left wall" {
    var g = Game.init(1);
    g.active = .{ .kind = .i, .rotation = 1, .x = -2, .y = 10 };
    try std.testing.expect(g.fits(g.active));
    try std.testing.expect(g.rotate(false));
    try std.testing.expectEqual(@as(i32, 0), g.active.x);
    try std.testing.expect(g.fits(g.active));
}

test "four full rows clear together and preserve blocks above" {
    var g = Game.init(2);
    for (g.board[20..24]) |*row| row.* = @splat(1);
    g.board[19][3] = 3;
    try std.testing.expectEqual(@as(u32, 4), g.clearRows());
    try std.testing.expectEqual(@as(u8, 3), g.board[23][3]);
    try std.testing.expectEqual(@as(u8, 0), g.board[19][3]);
}

test "hold allowed once per piece and restored after lock" {
    var g = Game.init(3);
    const initial = g.active.kind;
    g.hold();
    try std.testing.expectEqual(initial, g.held.?);
    const next_kind = g.active.kind;
    g.hold();
    try std.testing.expectEqual(next_kind, g.active.kind);
    g.hardDrop();
    try std.testing.expect(!g.hold_used);
    g.hold();
    try std.testing.expectEqual(initial, g.active.kind);
}

test "grounded piece locks after half a second" {
    var g = Game.init(4);
    g.active = g.ghost();
    g.tick(0.49, false);
    for (g.board) |row| for (row) |v| {
        try std.testing.expectEqual(@as(u8, 0), v);
    };
    g.tick(0.02, false);
    var count: usize = 0;
    for (g.board) |row| for (row) |v| {
        if (v != 0) {
            count += 1;
        }
    };
    try std.testing.expectEqual(@as(usize, 4), count);
}

test "blocked spawn ends game" {
    var g = Game.init(5);
    g.board[2] = @splat(1);
    g.board[3] = @splat(1);
    g.spawn(.t);
    try std.testing.expect(g.over);
}

test "back-to-back Tetrises and combo score at the current level" {
    var g = Game.init(6);
    for (0..2) |_| {
        g.board = @splat(@splat(0));
        g.board[19][0] = 1; // Prevent a perfect clear bonus.
        for (g.board[20..24]) |*row| {
            row.* = @splat(1);
            row[4] = 0;
        }
        g.active = .{ .kind = .i, .rotation = 1, .x = 2, .y = 20 };
        g.lock();
    }
    try std.testing.expectEqual(@as(u32, 8), g.lines);
    try std.testing.expectEqual(@as(u64, 2050), g.score);
    try std.testing.expect(g.back_to_back);
    try std.testing.expectEqual(@as(i32, 1), g.combo);
}

test "T-spin single uses occupied corners and rotation history" {
    var g = Game.init(7);
    g.active = .{ .kind = .t, .x = 3, .y = 21 };
    g.board[22] = @splat(1);
    for (3..6) |x| g.board[22][x] = 0;
    g.board[21][3] = 1;
    g.board[21][5] = 1;
    g.board[23][3] = 1;
    try std.testing.expectEqual(@as(u2, 0), g.spin());
    g.rotated = true;
    try std.testing.expectEqual(@as(u2, 2), g.spin());
    g.lock();
    try std.testing.expectEqual(@as(u32, 1), g.lines);
    try std.testing.expectEqual(@as(u64, 800), g.score);
}

test "perfect clear scores line points and bonus" {
    var g = Game.init(8);
    g.board[23] = @splat(1);
    for (3..7) |x| g.board[23][x] = 0;
    g.active = .{ .kind = .i, .x = 3, .y = 22 };
    g.lock();
    try std.testing.expectEqual(@as(u64, 900), g.score);
    try std.testing.expectEqualStrings("PERFECT CLEAR", g.event);
}

test "lock delay resets are capped at fifteen" {
    var g = Game.init(9);
    g.active = .{ .kind = .o, .x = 3, .y = 22 };
    for (0..20) |i| {
        g.lock_timer = 0.4;
        try std.testing.expect(g.move(if (i % 2 == 0) 1 else -1));
    }
    try std.testing.expectEqual(@as(u8, 15), g.lock_resets);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), g.lock_timer, 0.001);
    g.tick(0.11, false);
    try std.testing.expectEqual(@as(u32, 1), g.locks);
}

test "random play keeps active and ghost pieces inside legal space" {
    var rng = std.Random.DefaultPrng.init(100);
    for (0..100) |seed| {
        var g = Game.init(seed);
        for (0..200) |_| {
            if (g.over) break;
            switch (rng.random().intRangeAtMost(u8, 0, 5)) {
                0 => {
                    _ = g.move(-1);
                },
                1 => {
                    _ = g.move(1);
                },
                2 => {
                    _ = g.rotate(true);
                },
                3 => {
                    _ = g.rotate(false);
                },
                4 => g.hold(),
                5 => g.hardDrop(),
                else => unreachable,
            }
            if (!g.over) {
                try std.testing.expect(g.fits(g.active));
                var ghost_piece = g.ghost();
                try std.testing.expect(g.fits(ghost_piece));
                ghost_piece.y += 1;
                try std.testing.expect(!g.fits(ghost_piece));
                g.tick(0.05, rng.random().boolean());
            }
        }
    }
}

test "high-level gravity reaches the floor in one frame" {
    var g = Game.init(10);
    g.lines = 190;
    const landing = g.ghost();
    g.tick(1.0 / 60.0, false);
    try std.testing.expectEqual(landing.y, g.active.y);
    try std.testing.expectEqual(@as(u32, 0), g.locks);
}

test "starting a soft drop does not spend banked gravity time" {
    var g = Game.init(11);
    g.tick(0.9, false);
    const start = g.active.y;
    g.tick(1.0 / 60.0, true);
    try std.testing.expect(g.active.y - start <= 1);
}
