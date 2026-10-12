const std = @import("std");
const testing = std.testing;
const c = @import("context_abi_c");
const audio = @import("../audio.zig");
const video = @import("../video.zig");
const image = @import("../image.zig");
const context = @import("../context.zig");
const scene = @import("../scene.zig");
const Fixture = @import("scene_fixture_test.zig").Fixture;

const asset = "../core/src/tests/fixtures/video/testsrc-160x90-24fps-2s.mp4";
const missing = "../core/src/tests/fixtures/video/missing.mp4";
const frame_us: u32 = 41_667;

fn openAsset(external_audio: bool) !*video.Video {
    var detail: [256]u8 = undefined;
    return video.Video.open(testing.allocator, asset, external_audio, &detail);
}

// Mixing pulls the PCM stream as an output device would.
fn mix(value: *video.Video, frames: u32) !void {
    const output = try testing.allocator.alloc(f32, @as(usize, frames) * 2);
    defer testing.allocator.free(output);
    try testing.expectEqual(audio.Status.ok, audio.mixToBuffer(value.audio_engine.?, output.ptr, frames, 2));
}

// The PCM stream converts queued input on its own worker; wait until it can start.
fn prebuffer(value: *video.Video) !void {
    for (0..2000) |_| {
        _ = try value.update(0);
        if (value.audioStats().?.buffered_frames >= 12_000) return;
        std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "video open reports metadata and decodes the first frame natively" {
    const value = try openAsset(false);
    defer value.deinit();
    try testing.expectEqual(@as(u32, 160), value.info.width);
    try testing.expectEqual(@as(u32, 90), value.info.height);
    try testing.expectEqual(@as(u32, 1), value.info.has_audio);
    try testing.expectEqual(@as(u32, 48_000), value.info.audio_sample_rate);
    try testing.expectEqual(@as(u32, 2), value.info.audio_channels);
    try testing.expect(value.info.duration_us >= 1_900_000 and value.info.duration_us <= 2_100_000);

    try value.configureOutput(80, 45, false);
    try testing.expect(try value.update(0));
    const state = value.getState();
    try testing.expectEqual(@as(u32, 1), state.has_frame);
    try testing.expectEqual(@as(i64, 0), state.frame_pts_us);
    const frame = value.current_image.?;
    try testing.expectEqual(@as(u32, 80), frame.width());
    try testing.expectEqual(@as(u32, 45), frame.height());
    try testing.expectEqual(@as(u32, 0), frame.metadata.has_alpha);
}

test "video open failures expose the native error detail" {
    var detail: [256]u8 = undefined;
    try testing.expectError(error.OpenFailed, video.Video.open(testing.allocator, missing, false, &detail));
    try testing.expect(std.mem.sliceTo(&detail, 0).len > 0);
    try testing.expectError(error.InvalidArgument, video.Video.open(testing.allocator, "", false, &detail));
}

test "video frames reuse pooled images and skip busy ones" {
    const value = try openAsset(true);
    defer value.deinit();
    try testing.expect(try value.update(0));
    const first = value.current_image.?;

    // A drawn frame stays busy while a buffer retains it.
    first.retain();
    try testing.expect(try value.update(frame_us));
    try testing.expect(value.current_image.? != first);
    try testing.expectEqual(@as(u32, 2), first.ref_count);
    first.deinit();

    // Released pool images are refreshed in place instead of reallocated.
    var seen = std.ArrayList(*image.Image).empty;
    defer seen.deinit(testing.allocator);
    for (2..12) |index| {
        try testing.expect(try value.update(@intCast(index * frame_us)));
        const current = value.current_image.?;
        if (std.mem.findScalar(*image.Image, seen.items, current) == null) try seen.append(testing.allocator, current);
    }
    try testing.expect(seen.items.len <= 4);
}

test "video production drops frames while every pooled image is busy" {
    const value = try openAsset(true);
    defer value.deinit();
    var held: [4]*image.Image = undefined;
    for (&held, 0..) |*slot, index| {
        try testing.expect(try value.update(@intCast(index * frame_us)));
        slot.* = value.current_image.?;
        slot.*.retain();
    }
    const serial = value.state.frame_serial;
    try testing.expect(!try value.update(4 * frame_us));
    try testing.expectEqual(serial, value.state.frame_serial);
    try testing.expect(!try value.prepare(5 * frame_us));
    for (held) |frame| frame.deinit();
    try testing.expect(try value.update(4 * frame_us));
}

test "video frame preparation runs asynchronously and the scheduler presents at its deadline" {
    const value = try openAsset(true);
    defer value.deinit();
    try testing.expect(try value.update(0));
    try testing.expect(try value.prepareNext(frame_us));
    value.drainPreparation();
    const prepared_pts = value.state.prepared_pts_us;
    try testing.expect(prepared_pts > 0);
    const presented = value.state.frame_serial;

    try value.schedule(0, frame_us);
    try testing.expectEqual(presented, value.state.frame_serial);
    try value.schedule(prepared_pts, frame_us);
    try testing.expect(value.state.frame_serial != presented);
    try testing.expectEqual(prepared_pts, value.state.frame_pts_us);
    try testing.expectEqual(@as(i64, -1), value.state.prepared_pts_us);
}

test "video scheduler drops a stale prepared frame and seek clears the slot" {
    const value = try openAsset(true);
    defer value.deinit();
    try testing.expect(try value.update(0));
    try testing.expect(try value.prepare(frame_us));
    value.drainPreparation();
    try testing.expect(value.prepared_image != null);
    try value.schedule(1_000_000, frame_us);
    try testing.expect(value.prepared_image == null);
    try testing.expect(value.resync_pending);

    try testing.expect(try value.prepare(frame_us));
    value.drainPreparation();
    try value.seek(500_000);
    try testing.expect(value.prepared_image == null);
    try testing.expectEqual(@as(u32, 0), value.state.has_frame);
    try testing.expect(try value.update(500_000));
    try testing.expect(value.state.frame_pts_us <= 500_000 and value.state.frame_pts_us > 500_000 - frame_us);
}

test "video reaches the end of the stream" {
    const value = try openAsset(true);
    defer value.deinit();
    _ = try value.update(value.info.duration_us);
    try testing.expectEqual(@as(u32, 1), value.state.ended);
}

test "video audio streams PCM through the audio stream path and drives the media clock" {
    const value = try openAsset(false);
    defer value.deinit();
    value.setAudioOffline(true);
    value.play();
    try prebuffer(value);
    var state = value.getState();
    try testing.expectEqual(@as(u32, 1), state.buffering);
    try testing.expectEqual(@as(i64, 0), state.current_time_us);

    try mix(value, 4800);
    state = value.getState();
    try testing.expectEqual(@as(u32, 1), state.audio_active);
    try testing.expectEqual(@as(u64, 4800), state.audio_consumed_frames);
    try testing.expectEqual(@as(i64, 100_000), state.current_time_us);
    try testing.expect(state.audio_produced_frames >= 12_000);

    // Pausing suspends the mixer, so the clock and queued PCM hold.
    value.pause();
    _ = try value.update(0);
    try mix(value, 4800);
    try testing.expectEqual(@as(u64, 4800), value.getState().audio_consumed_frames);
    value.play();
    _ = try value.update(0);
    try mix(value, 4800);
    try testing.expectEqual(@as(i64, 200_000), value.getState().current_time_us);
}

test "video mute outputs silence while the clock advances" {
    const value = try openAsset(false);
    defer value.deinit();
    value.setAudioOffline(true);
    try value.setMuted(true);
    value.play();
    try prebuffer(value);
    var output: [9600]f32 = undefined;
    try testing.expectEqual(audio.Status.ok, audio.mixToBuffer(value.audio_engine.?, &output, 4800, 2));
    for (output) |sample| try testing.expectEqual(@as(f32, 0), sample);
    try testing.expectEqual(@as(i64, 100_000), value.getState().current_time_us);
}

test "video seek replaces queued PCM and restarts the clock at the target" {
    const value = try openAsset(false);
    defer value.deinit();
    value.setAudioOffline(true);
    value.play();
    try prebuffer(value);
    try mix(value, 4800);
    try value.seek(1_000_000);
    var state = value.getState();
    try testing.expectEqual(@as(u64, 0), state.audio_consumed_frames);
    try testing.expectEqual(@as(u64, 0), state.audio_produced_frames);
    try prebuffer(value);
    try mix(value, 4800);
    state = value.getState();
    try testing.expectEqual(@as(i64, 1_100_000), state.current_time_us);
}

test "video external audio decodes PCM through manual reads" {
    const value = try openAsset(true);
    defer value.deinit();
    try testing.expect(value.audio_engine == null);
    var samples: [4096 * 2]f32 = undefined;
    var total: u64 = 0;
    var peak: f32 = 0;
    while (true) {
        const frames = try value.readAudio(&samples, 4096);
        if (frames == 0) break;
        for (samples[0 .. frames * 2]) |sample| peak = @max(peak, @abs(sample));
        total += frames;
    }
    try testing.expect(total >= 90_000 and total <= 100_000);
    try testing.expect(peak > 0.05);

    const owned = try openAsset(false);
    defer owned.deinit();
    try testing.expectError(error.InvalidArgument, owned.readAudio(&samples, 4096));
}

test "video output reconfiguration keeps the current frame presentable" {
    const value = try openAsset(true);
    defer value.deinit();
    try testing.expect(try value.update(0));
    const before = value.current_image.?;
    try value.configureOutput(40, 20, true);
    try testing.expectEqual(before, value.current_image.?);
    try testing.expectEqual(@as(u32, 1), value.state.has_frame);
    try testing.expect(try value.update(0));
    try testing.expectEqual(@as(u32, 40), value.current_image.?.width());
    try testing.expectEqual(@as(u32, 20), value.current_image.?.height());
}

const frame_options: scene.FrameOptions = .{
    .background = .{ 0, 0, 0, 255 },
    .use_mouse = false,
    .excluded_hit_num = 0,
    .max_layout_rounds = 8,
    .max_host_requests = 64,
};

fn videoNode(f: Fixture) !context.Handle {
    const node = try f.owner.sceneCreateNode(f.id, c.OT_SCENE_VIDEO, 2);
    try f.owner.sceneSetStyle(node, 4, 0, 0, 1, 8, 1);
    try f.owner.sceneSetStyle(node, 4, 1, 0, 1, 4, 1);
    try f.owner.sceneMoveNode(node, f.root, 0);
    return node;
}

fn playerOf(f: Fixture, node: context.Handle) !*video.Player {
    return (try f.owner.raw().getRenderable(node)).scene_node.?.control.video.player.?;
}

fn paint(f: Fixture) !void {
    if (f.state.painted) |painted| try f.owner.sceneFrameCancel(f.id, painted.ticket.frame_id);
    _ = try f.step(null, frame_options, c.OT_SCENE_FRAME_DONE, null);
}

test "video scene nodes paint the current frame through the image path" {
    const f = try Fixture.init(testing.allocator, 8, 4, .{});
    defer f.deinit();
    const node = try videoNode(f);
    try f.owner.sceneSetVideo(node, .fill, null);
    // Nothing paints before a source opens.
    try paint(f);
    const info = try f.owner.videoOpen(node, asset);
    try testing.expectEqual(@as(u32, 160), info.width);
    try paint(f);
    const value = try playerOf(f, node);
    const frame = value.video.current_image.?;
    // Without a pixel resolution a cell counts as 2x4 pixels.
    try testing.expectEqual(@as(u32, 16), frame.width());
    try testing.expectEqual(@as(u32, 16), frame.height());
    try testing.expect(frame.render_id != 0);
    // The painted buffer retains the frame, so the decoder skips it until release.
    try testing.expect(frame.ref_count > 1);
    try testing.expectEqual(@as(usize, 1), f.cli.getNextBuffer().image_placements.items.len);
}

test "video scene playback advances frames natively and ends without looping" {
    const f = try Fixture.init(testing.allocator, 8, 4, .{});
    defer f.deinit();
    const node = try videoNode(f);
    _ = try f.owner.videoOpen(node, asset);
    const value = try playerOf(f, node);
    // A failed audio device leaves the wall clock in charge.
    value.video.audio_failed = true;
    try f.owner.videoControl(node, video.Player.play, .{});
    try paint(f);
    const first = value.video.current_image.?.render_id;
    var advanced = false;
    for (0..200) |_| {
        std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
        try paint(f);
        if (value.video.current_image.?.render_id != first) {
            advanced = true;
            break;
        }
    }
    try testing.expect(advanced);
    try testing.expect(value.video.state.frame_pts_us > 0);

    try f.owner.videoControl(node, video.Player.seek, .{value.video.info.duration_us - 10_000});
    try paint(f);
    std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
    try paint(f);
    const state = try f.owner.videoGetState(node);
    try testing.expect(state.ended);
    try testing.expect(!state.playing);
    try testing.expectEqual(value.video.info.duration_us, state.current_time_us);
}

test "video scene loop restarts playback at the end" {
    const f = try Fixture.init(testing.allocator, 8, 4, .{});
    defer f.deinit();
    const node = try videoNode(f);
    _ = try f.owner.videoOpen(node, asset);
    const value = try playerOf(f, node);
    value.video.audio_failed = true;
    try f.owner.videoControl(node, video.Player.setLoop, .{true});
    try f.owner.videoControl(node, video.Player.play, .{});
    try f.owner.videoControl(node, video.Player.seek, .{value.video.info.duration_us - 10_000});
    std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
    try paint(f);
    const state = try f.owner.videoGetState(node);
    try testing.expect(state.playing);
    try testing.expect(!state.ended);
    try testing.expect(state.current_time_us < 500_000);
}

test "video scene open failures keep their detail" {
    const f = try Fixture.init(testing.allocator, 8, 4, .{});
    defer f.deinit();
    const node = try videoNode(f);
    try testing.expectError(error.OpenFailed, f.owner.videoOpen(node, missing));
    try testing.expect((try f.owner.videoGetError(node)).len > 0);
    try testing.expectError(error.InvalidOptions, f.owner.videoControl(node, video.Player.play, .{}));
    const box = try f.owner.sceneCreateNode(f.id, c.OT_SCENE_BOX, 3);
    try testing.expectError(error.WrongKind, f.owner.videoOpen(box, asset));
    // Closing clears the failure.
    _ = try f.owner.videoOpen(node, "");
    try testing.expectEqual(@as(usize, 0), (try f.owner.videoGetError(node)).len);
}
