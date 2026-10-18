const std = @import("std");

const core = @import("zetris");
const rg = @import("raygui");
const rl = @import("raylib");

const cell = 30;
const board_x = 322;
const board_y = 132;

const bg = color(13, 17, 27);
const panel = color(21, 28, 42);
const muted = color(126, 145, 168);
const ink = color(232, 240, 248);
const accent = color(75, 218, 205);
const palette = [_]rl.Color{
    color(58, 207, 227),
    color(247, 205, 75),
    color(174, 114, 238),
    color(99, 211, 134),
    color(240, 105, 119),
    color(88, 137, 240),
    color(246, 166, 78),
};

fn color(r: u8, g: u8, b: u8) rl.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn hex(c: rl.Color) i32 {
    return rl.colorToInt(c);
}

/// Theme raygui's controls with the Zetris palette. DEFAULT properties apply to every control.
fn styleGui() void {
    rg.setStyle(.default, .text_size, 14);
    rg.setStyle(.default, .border_color_normal, hex(color(63, 82, 105)));
    rg.setStyle(.default, .base_color_normal, hex(panel));
    rg.setStyle(.default, .text_color_normal, hex(muted));
    rg.setStyle(.default, .border_color_focused, hex(accent));
    rg.setStyle(.default, .base_color_focused, hex(color(29, 40, 58)));
    rg.setStyle(.default, .text_color_focused, hex(ink));
    rg.setStyle(.default, .border_color_pressed, hex(accent));
    rg.setStyle(.default, .base_color_pressed, hex(accent));
    rg.setStyle(.default, .text_color_pressed, hex(bg));
    rg.setStyle(.button, .text_color_normal, hex(ink));

    // Checkbox marks, labels, and slider fills use text colors, so keep them visible when pressed.
    rg.setStyle(.checkbox, .text_color_normal, hex(accent));
    rg.setStyle(.checkbox, .text_color_pressed, hex(accent));
    rg.setStyle(.label, .text_color_pressed, hex(accent));
    rg.setStyle(.slider, .text_color_pressed, hex(accent));
}

fn text(s: [:0]const u8, x: i32, y: i32, size: i32, tint: rl.Color) void {
    rl.drawText(s, x, y, size, tint);
}

fn number(value: anytype, x: i32, y: i32, size: i32) void {
    var buf: [40]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, "{d}", .{value}) catch unreachable;
    text(s, x, y, size, ink);
}

fn box(x: i32, y: i32, w: i32, h: i32) void {
    rl.drawRectangle(x, y, w, h, panel);
    rl.drawRectangleLines(x, y, w, h, color(41, 53, 72));
}

fn block(x: i32, y: i32, size: i32, tint: rl.Color, ghost: bool) void {
    if (ghost) {
        rl.drawRectangleLines(x + 2, y + 2, size - 4, size - 4, tint);
        return;
    }
    rl.drawRectangle(x + 1, y + 1, size - 2, size - 2, tint);
    rl.drawRectangle(x + 3, y + 3, size - 6, 3, .{ .r = 255, .g = 255, .b = 255, .a = 65 });
    rl.drawRectangle(x + 3, y + size - 6, size - 6, 3, .{ .r = 0, .g = 0, .b = 0, .a = 40 });
}

fn drawPiece(p: core.Piece, ghost: bool) void {
    for (core.cells(p)) |pos| {
        if (pos.y < core.hidden) continue;
        block(
            board_x + pos.x * cell,
            board_y + (pos.y - core.hidden) * cell,
            cell,
            palette[@intFromEnum(p.kind)],
            ghost,
        );
    }
}

fn preview(kind: core.Kind, x: i32, y: i32) void {
    const positions = core.cells(.{ .kind = kind, .x = 0, .y = 0 });
    var min_x: i32 = 4;
    var max_x: i32 = 0;
    var min_y: i32 = 4;
    for (positions) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
    }
    const offset = @divTrunc(160 - (max_x - min_x + 1) * 24, 2);
    for (positions) |p| block(
        x + offset + (p.x - min_x) * 24,
        y + (p.y - min_y) * 24,
        24,
        palette[@intFromEnum(kind)],
        false,
    );
}

/// raylib copies the PCM, so the caller can release its samples after loading.
fn loadSound(samples: []const i16, sample_rate: u32, volume: f32) rl.Sound {
    const sound = rl.loadSoundFromWave(.{
        .frameCount = @intCast(samples.len),
        .sampleRate = sample_rate,
        .sampleSize = 16,
        .channels = 1,
        .data = @constCast(samples.ptr),
    });
    if (rl.isSoundValid(sound)) rl.setSoundVolume(sound, volume);
    return sound;
}

const Audio = struct {
    sounds: [4]?rl.Sound = @splat(null),
    muted: bool = false,
    volume: f32 = 1,
    fn init() Audio {
        rl.initAudioDevice();
        var audio: Audio = .{};
        if (!rl.isAudioDeviceReady()) {
            std.log.err("AUDIO: No playback device", .{});
            return audio;
        }
        const tones = [_]f32{ 330, 150, 660, 100 };
        const amplitudes = [_]f32{ 9000, 9000, 9000, 9000 };

        // The rising line-clear tone sounds louder than the lower rotation tone.
        const volumes = [_]f32{ 1.0, 1.0, 0.5, 1.0 };
        for (tones, 0..) |frequency, index| {
            var samples: [6600]i16 = undefined;
            for (&samples, 0..) |*sample, i| {
                const t = @as(f32, @floatFromInt(i)) / 22050;
                const envelope = @min(t * 200, 1) * @max(0, 1 - t / 0.299);
                const pitch = if (index == 2) frequency * (1 + t * 3) else frequency;
                sample.* = @intFromFloat(
                    @sin(2 * std.math.pi * pitch * t) * amplitudes[index] * envelope,
                );
            }
            const sound = loadSound(&samples, 22050, volumes[index]);
            if (rl.isSoundValid(sound)) {
                audio.sounds[index] = sound;
            } else {
                std.log.err("AUDIO: Failed to load synthesized effect {d}", .{index});
            }
        }
        var loaded: usize = 0;
        for (audio.sounds) |sound| {
            if (sound != null) loaded += 1;
        }
        std.log.info("AUDIO: Loaded {d}/4 effects", .{loaded});
        return audio;
    }
    fn available(audio: *const Audio) bool {
        for (audio.sounds) |sound| {
            if (sound != null) return true;
        }
        return false;
    }
    fn setMuted(audio: *Audio, off: bool) void {
        audio.muted = off;
        std.log.info("AUDIO: {s}", .{if (off) "muted" else "enabled"});
        if (!off) audio.play(0);
    }
    fn play(audio: *const Audio, index: usize) void {
        if (!audio.muted) {
            if (audio.sounds[index]) |sound| rl.playSound(sound);
        }
    }
    fn deinit(audio: *Audio) void {
        for (audio.sounds) |maybe| if (maybe) |sound| rl.unloadSound(sound);
        if (rl.isAudioDeviceReady()) rl.closeAudioDevice();
    }
};

const Repeat = struct {
    direction: i32 = 0,
    timer: f32 = 0,
    repeating: bool = false,
    fn update(r: *Repeat, g: *core.Game, dt: f32) void {
        const left = rl.isKeyDown(.left);
        const right = rl.isKeyDown(.right);
        var direction: i32 = if (left == right) 0 else if (left) -1 else 1;
        if (left and right) {
            if (rl.isKeyPressed(.left)) {
                direction = -1;
            } else if (rl.isKeyPressed(.right)) {
                direction = 1;
            } else {
                direction = r.direction;
            }
        }
        if (direction != r.direction) {
            r.* = .{ .direction = direction };
            if (direction != 0) {
                _ = g.move(direction);
            }
        } else if (direction != 0) {
            r.timer += dt;
            const interval: f32 = if (r.repeating) 0.045 else 0.15;
            if (r.timer >= interval) {
                r.timer -= interval;
                r.repeating = true;
                _ = g.move(direction);
            }
        }
    }
};

fn render(g: *const core.Game, paused: bool, best: u64, audio: *const Audio) void {
    rl.clearBackground(bg);
    text("ZETRIS", 92, 38, 44, ink);
    box(92, 132, 190, 130);
    text("HOLD", 108, 148, 16, if (g.hold_used) muted else accent);
    if (g.held) |k| preview(k, 107, 195);
    box(92, 286, 190, 282);
    text("SCORE", 112, 309, 16, muted);
    number(g.score, 112, 337, 30);
    text("BEST THIS SESSION", 112, 386, 14, muted);
    number(best, 112, 410, 22);
    text("LEVEL", 112, 463, 16, muted);
    number(g.level(), 112, 488, 28);
    text("LINES", 206, 463, 16, muted);
    number(g.lines, 206, 488, 28);
    box(92, 592, 190, 140);
    text("NEXT LEVEL", 108, 610, 16, muted);
    number(10 - g.lines % 10, 108, 637, 30);
    text("LINES TO GO", 108, 676, 14, muted);
    rl.drawRectangle(108, 705, 158, 5, color(42, 53, 71));
    rl.drawRectangle(108, 705, @intCast(g.lines % 10 * 158 / 10), 5, accent);
    rl.drawRectangle(board_x - 2, board_y - 2, 304, 604, color(63, 82, 105));
    rl.drawRectangle(board_x, board_y, 300, 600, color(10, 14, 23));
    for (0..21) |row| rl.drawLine(
        board_x,
        board_y + @as(i32, @intCast(row)) * cell,
        board_x + 300,
        board_y + @as(i32, @intCast(row)) * cell,
        color(25, 32, 45),
    );
    for (0..11) |col| rl.drawLine(
        board_x + @as(i32, @intCast(col)) * cell,
        board_y,
        board_x + @as(i32, @intCast(col)) * cell,
        board_y + 600,
        color(25, 32, 45),
    );
    for (core.hidden..core.height) |y| for (0..core.width) |x| {
        const v = g.board[y][x];
        if (v != 0) block(
            board_x + @as(i32, @intCast(x)) * cell,
            board_y + @as(i32, @intCast(y - core.hidden)) * cell,
            cell,
            palette[v - 1],
            false,
        );
    };
    if (g.clear_time > 0) {
        for (core.hidden..core.height) |y| {
            if (g.clear_mask & (@as(u32, 1) << @intCast(y)) != 0) {
                rl.drawRectangle(
                    board_x,
                    board_y + @as(i32, @intCast(y - core.hidden)) * cell,
                    300,
                    cell,
                    .{ .r = 232, .g = 255, .b = 255, .a = @intFromFloat(g.clear_time * 900) },
                );
            }
        }
    }
    if (!g.over) {
        drawPiece(g.ghost(), true);
        drawPiece(g.active, false);
    }
    box(662, 132, 190, 382);
    text("NEXT", 680, 148, 16, accent);
    for (g.queue, 0..) |kind, i| preview(kind, 677, 187 + @as(i32, @intCast(i)) * 63);
    box(662, 538, 190, 194);
    text("CONTROLS", 680, 555, 16, accent);
    const command_x = 678 + rl.measureText("ARROWS    ", 14);
    text("ARROWS", 678, 587, 14, ink);
    text("Move", command_x, 587, 14, ink);
    text("X", 678, 610, 14, ink);
    text("Rotate", command_x, 610, 14, ink);
    text("Z", 678, 633, 14, ink);
    text("Reverse", command_x, 633, 14, ink);
    text("SPACE", 678, 656, 14, ink);
    text("Drop", command_x, 656, 14, ink);
    text("SHIFT", 678, 679, 14, ink);
    text("Hold", command_x, 679, 14, ink);
    text("P", 678, 702, 14, ink);
    text("Pause", command_x, 702, 14, ink);
    if (g.event_time > 0) {
        const tw = rl.measureText(g.event, 20);
        text(g.event, board_x + @divTrunc(300 - tw, 2), 754, 20, accent);
    }
    text("R  RESTART", 92, 794, 14, muted);
    if (!audio.available()) {
        const sound_label: [:0]const u8 = "SOUND UNAVAILABLE";
        text(sound_label, board_x + @divTrunc(300 - rl.measureText(sound_label, 14), 2), 794, 14, muted);
    }
    const quit_label: [:0]const u8 = "ESC  QUIT";
    text(quit_label, 944 - 92 - rl.measureText(quit_label, 14), 794, 14, muted);
    if (paused or g.over) {
        rl.drawRectangle(board_x, board_y, 300, 600, .{ .r = 10, .g = 14, .b = 23, .a = 225 });
        const title: [:0]const u8 = if (g.over) "GAME OVER" else "PAUSED";
        text(title, board_x + @divTrunc(300 - rl.measureText(title, 30), 2), 360, 30, ink);
        const hint: [:0]const u8 = if (g.over) "PRESS R TO RESTART" else "PRESS P TO RESUME";
        text(hint, board_x + @divTrunc(300 - rl.measureText(hint, 16), 2), 405, 16, accent);
    }
}

const Command = enum { none, unpause, restart };

/// Draw the raygui widgets. raygui is immediate-mode, so this also handles their mouse input.
fn controls(g: *const core.Game, paused: bool, audio: *Audio) Command {
    var command: Command = .none;
    if (paused or g.over) {
        var y: f32 = 450;
        if (!g.over) {
            if (rg.button(.init(board_x + 70, y, 160, 36), "RESUME")) command = .unpause;
            y += 46;
        }
        if (rg.button(.init(board_x + 70, y, 160, 36), "RESTART")) command = .restart;
    }
    if (audio.available()) {
        var enabled = !audio.muted;
        if (rg.checkBox(.init(board_x, 793, 14, 14), "SOUND", &enabled)) audio.setMuted(!enabled);
        var buf: [8]u8 = undefined;
        const percent = std.fmt.bufPrintZ(&buf, "{d}%", .{@round(audio.volume * 100)}) catch unreachable;
        const slider_width = 136;
        const label_width = rg.getTextWidth("100%");
        const padding = rg.getStyle(.slider, .text_padding);
        const slider_x = board_x + 300 - label_width - padding - slider_width;
        if (rg.sliderBar(.init(@floatFromInt(slider_x), 793, slider_width, 14), null, percent, &audio.volume, 0, 1) != 0) {
            rl.setMasterVolume(audio.volume);
        }
    }
    return command;
}

pub fn main() void {
    rl.initWindow(944, 850, "Zetris");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    var audio = Audio.init();
    defer audio.deinit();
    styleGui();

    // The raylib timer provides a varying seed without OS I/O in the core.
    var seed: u64 = @intFromFloat(rl.getTime() * 1_000_000_000);
    var game = core.Game.init(seed);
    var paused = false;
    var best: u64 = 0;
    var repeat: Repeat = .{};

    // Widget clicks are reported while drawing, so apply them on the next frame.
    var command: Command = .none;
    while (!rl.windowShouldClose()) {
        const dt = @min(rl.getFrameTime(), 0.1);
        const old_locks = game.locks;
        const old_lines = game.lines;
        const old_over = game.over;
        if (rl.isKeyPressed(.r) or command == .restart) {
            seed +%= 0x9e3779b97f4a7c15;
            game = core.Game.init(seed);
            paused = false;
            repeat = .{};
        }
        if ((rl.isKeyPressed(.p) or command == .unpause) and !game.over) {
            paused = !paused;
            repeat = .{};
        }
        if (!rl.isWindowFocused() and !game.over) {
            paused = true;
        }
        if (!paused and !game.over) {
            repeat.update(&game, dt);
            if (rl.isKeyPressed(.x)) {
                if (game.rotate(true)) audio.play(0);
            }
            if (rl.isKeyPressed(.z)) {
                if (game.rotate(false)) audio.play(0);
            }
            if (rl.isKeyPressed(.left_shift) or rl.isKeyPressed(.right_shift)) {
                game.hold();
            }
            if (rl.isKeyPressed(.space)) {
                game.hardDrop();
            } else {
                game.tick(dt, rl.isKeyDown(.down));
            }
        }
        if (!old_over and game.over) {
            audio.play(3);
        } else if (game.lines > old_lines) {
            audio.play(2);
        } else if (game.locks > old_locks) {
            audio.play(1);
        }
        best = @max(best, game.score);
        rl.beginDrawing();
        render(&game, paused, best, &audio);
        command = controls(&game, paused, &audio);
        rl.endDrawing();
    }
}
