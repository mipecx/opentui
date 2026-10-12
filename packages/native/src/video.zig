const std = @import("std");
const builtin = @import("builtin");
const io = if (builtin.is_test) std.testing.io else @import("root").io;
const audio = @import("audio.zig");
const image = @import("image.zig");

const Allocator = std.mem.Allocator;

const Decoder = opaque {};
pub const audio_sample_rate: u32 = 48_000;
const audio_capacity_frames: u32 = 24_000;
const audio_decode_frames: u32 = 4096;
const audio_capacity_ms: u32 = 500;
const audio_startup_ms: u32 = 250;
// Current, prepared, in-flight, and frames whose published handles await release.
const frame_pool_capacity = 4;

pub const Info = extern struct {
    duration_us: i64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    fps_num: u32 = 0,
    fps_den: u32 = 1,
    has_audio: u32 = 0,
    audio_sample_rate: u32 = 0,
    audio_channels: u32 = 0,
};

pub const State = extern struct {
    current_time_us: i64 = 0,
    frame_pts_us: i64 = -1,
    frame_serial: u64 = 0,
    has_frame: u32 = 0,
    ended: u32 = 0,
    playing: u32 = 0,
    buffering: u32 = 0,
    audio_active: u32 = 0,
    audio_ended: u32 = 0,
    audio_failed: u32 = 0,
    audio_queued_frames: u32 = 0,
    audio_consumed_frames: u64 = 0,
    audio_produced_frames: u64 = 0,
    audio_underruns: u64 = 0,
    prepared_pts_us: i64 = -1,
    sync_lead_us: u32 = 0,
    prepare_time_us: u32 = 0,
};

const latency_window_size = 30;

pub const LatencyWindow = struct {
    samples: [latency_window_size]u32 = [_]u32{0} ** latency_window_size,
    count: u8 = 0,
    cursor: u8 = 0,

    pub fn add(self: *LatencyWindow, sample: u32) void {
        self.samples[self.cursor] = sample;
        self.cursor = @intCast((@as(usize, self.cursor) + 1) % latency_window_size);
        if (self.count < latency_window_size) self.count += 1;
    }

    pub fn maximum(self: *const LatencyWindow) u32 {
        var result: u32 = 0;
        for (self.samples[0..self.count]) |sample| result = @max(result, sample);
        return result;
    }

    fn reset(self: *LatencyWindow) void {
        self.* = .{};
    }
};

const PreparedFrame = struct {
    value: *image.Image,
    pts_us: i64,
    serial: u64,
};

const ProduceRequest = struct {
    target_us: i64,
    known_frame_serial: u64,
    known_prepared_serial: u64,
    slot: usize,
};

const ProduceOutcome = struct {
    frame: ?PreparedFrame = null,
    reached_end: bool = false,
    failed: ?anyerror = null,
    elapsed_us: u32 = 0,
};

extern fn otv_open(
    path: [*:0]const u8,
    out_decoder: *?*Decoder,
    out_info: *Info,
    error_out: [*]u8,
    error_cap: u32,
) c_int;
extern fn otv_close(decoder: *?*Decoder) void;
extern fn otv_seek(decoder: *Decoder, target_us: i64) c_int;
extern fn otv_seek_video(decoder: *Decoder, target_us: i64) c_int;
extern fn otv_set_output_size(decoder: *Decoder, width: u32, height: u32, cover: u32) c_int;
extern fn otv_decode_frame(
    decoder: *Decoder,
    target_us: i64,
    out_rgba: *?[*]const u8,
    out_width: *u32,
    out_height: *u32,
    out_stride: *u32,
    out_pts_us: *i64,
    out_serial: *u64,
) c_int;
extern fn otv_read_audio(decoder: *Decoder, out_samples: ?[*]f32, capacity_frames: u32, out_frames: *u32) c_int;
extern fn otv_last_error(decoder: *const Decoder) [*:0]const u8;
extern fn otv_stream_error(decoder: *const Decoder, audio_stream: u32) [*:0]const u8;

fn nowUs() i64 {
    return @intCast(std.Io.Clock.now(.awake, io).toMicroseconds());
}

fn elapsedSince(started: i64) u32 {
    return @intCast(std.math.clamp(nowUs() - started, 0, std.math.maxInt(u32)));
}

/// Decodes one media file. Frames are native images; audio plays through a private engine
/// and its PCM stream, whose played frames are the media clock.
pub const Video = struct {
    allocator: Allocator,
    decoder: *Decoder,
    info: Info,
    state: State = .{},
    // Frames are pooled images refreshed in place with image.updatePixels. Each
    // publication hands out a retained handle; a retained image is busy and is
    // skipped until its handles are released. current/prepared borrow pool images.
    frame_pool: [frame_pool_capacity]?*image.Image = @splat(null),
    current_image: ?*image.Image = null,
    prepared_image: ?*image.Image = null,
    prepared_serial: u64 = 0,
    last_produced_pts_us: i64 = -1,
    // Set when the media position no longer follows production stepping
    // (start, seek, reconfiguration, or a dropped stale frame); the next
    // preparation then re-anchors to the clock instead of stepping.
    resync_pending: bool = true,
    preparation_latency: LatencyWindow = .{},
    // Counts presented frames; never resets, so painters can detect new pixels.
    published: u64 = 0,
    output_width: u32,
    output_height: u32,
    output_cover: bool = false,
    audio_engine: ?*audio.Engine = null,
    audio_stream: u32 = 0,
    audio_buffer: ?[]f32 = null,
    audio_ended: bool = false,
    audio_failed: bool = false,
    audio_offline: bool = false,
    mixer_running: bool = false,
    wants_playback: bool = false,
    muted: bool = false,
    volume: f32 = 1,
    audio_base_us: i64 = 0,
    audio_produced_frames: u64 = 0,
    audio_start_thread: ?std.Thread = null,
    audio_device_status: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    av_sync_offset_us: i64 = 0,
    // Frame production runs on a dedicated worker so decode, hardware
    // readback, and scaling overlap with rendering. The worker is the only
    // thread touching the decoder's video stream; the caller keeps audio,
    // seeking, and reconfiguration, which quiesce the worker first. Results
    // hand over fully built frames under the mutex.
    worker: ?std.Thread = null,
    worker_mutex: std.Io.Mutex = .init,
    worker_wake: std.Io.Condition = .init,
    worker_done: std.Io.Condition = .init,
    worker_pending: ?ProduceRequest = null,
    worker_busy: bool = false,
    worker_quit: bool = false,
    worker_result: ?ProduceOutcome = null,
    last_error_buf: [256]u8 = [_]u8{0} ** 256,
    last_error_len: usize = 0,

    /// With external_audio the caller owns the audio: no engine is created and
    /// decoded 48 kHz stereo PCM is pulled through readAudio. A failed open
    /// writes its detail to error_out.
    pub fn open(allocator: Allocator, path: []const u8, external_audio: bool, error_out: []u8) !*Video {
        if (error_out.len > 0) error_out[0] = 0;
        if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArgument;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        var decoder: ?*Decoder = null;
        var info = Info{};
        var detail: [256]u8 = [_]u8{0} ** 256;
        if (otv_open(path_z.ptr, &decoder, &info, &detail, detail.len) != 0 or decoder == null) {
            const message = std.mem.sliceTo(&detail, 0);
            const length = @min(message.len, error_out.len -| 1);
            @memcpy(error_out[0..length], message[0..length]);
            if (error_out.len > 0) error_out[length] = 0;
            return error.OpenFailed;
        }
        errdefer otv_close(&decoder);
        const video = try allocator.create(Video);
        errdefer allocator.destroy(video);
        video.* = .{
            .allocator = allocator,
            .decoder = decoder.?,
            .info = info,
            .output_width = info.width,
            .output_height = info.height,
        };
        if (info.has_audio != 0 and !external_audio) {
            const engine = audio.create(allocator, &.{ .sample_rate = audio_sample_rate, .playback_channels = 2 }) orelse
                return error.OutOfMemory;
            errdefer audio.destroy(engine);
            video.audio_buffer = try allocator.alloc(f32, audio_decode_frames * 2);
            errdefer allocator.free(video.audio_buffer.?);
            video.audio_engine = engine;
            try video.openAudioStream();
        }
        return video;
    }

    pub fn deinit(self: *Video) void {
        self.quiesceWorker();
        self.worker_mutex.lockUncancelable(io);
        self.worker_quit = true;
        self.worker_wake.broadcast(io);
        self.worker_mutex.unlock(io);
        if (self.worker) |thread| thread.join();
        if (self.audio_start_thread) |thread| thread.join();
        if (self.audio_engine) |engine| audio.destroy(engine);
        if (self.audio_buffer) |buffer| self.allocator.free(buffer);
        for (self.frame_pool) |slot| if (slot) |value| value.deinit();
        var decoder: ?*Decoder = self.decoder;
        otv_close(&decoder);
        self.allocator.destroy(self);
    }

    fn openAudioStream(self: *Video) !void {
        const engine = self.audio_engine orelse return;
        const options: audio.StreamOptions = .{
            .capacity_ms = audio_capacity_ms,
            .startup_ms = audio_startup_ms,
            .resume_ms = audio_startup_ms,
            .volume = 1,
            .pan = 0,
            .group_id = 0,
            .format = audio.StreamFormat.pcm,
            .sample_rate = audio_sample_rate,
            .channels = 2,
        };
        var stream_id: u32 = 0;
        if (audio.createStream(engine, &options, &stream_id) != audio.Status.ok) return error.OutOfMemory;
        self.audio_stream = stream_id;
    }

    fn closeAudioStream(self: *Video) void {
        const engine = self.audio_engine orelse return;
        if (self.audio_stream == 0) return;
        var stats: audio.StreamStats = undefined;
        _ = audio.closeStream(engine, self.audio_stream, audio.StreamCloseReason.disposed, &stats);
        self.audio_stream = 0;
    }

    pub fn audioStats(self: *Video) ?audio.StreamStats {
        const engine = self.audio_engine orelse return null;
        if (self.audio_stream == 0) return null;
        var stats: audio.StreamStats = undefined;
        if (audio.getStreamStats(engine, self.audio_stream, &stats) != audio.Status.ok) return null;
        return stats;
    }

    pub fn configureOutput(self: *Video, width: u32, height: u32, cover: bool) !void {
        if (width == 0 or height == 0) return error.InvalidArgument;
        if (width == self.output_width and height == self.output_height and cover == self.output_cover) return;
        self.quiesceWorker();
        if (otv_set_output_size(self.decoder, width, height, @intFromBool(cover)) != 0) return error.DecodeFailed;
        self.output_width = width;
        self.output_height = height;
        self.output_cover = cover;
        if (otv_seek_video(self.decoder, self.state.current_time_us) != 0) return error.SeekFailed;
        // The stale-sized frame stays presentable until its replacement is
        // decoded, so reconfiguring does not blank the placement.
        self.resetScheduler();
        self.state.frame_serial = 0;
        self.state.frame_pts_us = -1;
    }

    pub fn seek(self: *Video, target_us: i64) !void {
        if (target_us < 0) return error.InvalidArgument;
        self.quiesceWorker();
        if (otv_seek(self.decoder, target_us) != 0) return error.SeekFailed;
        if (self.audio_engine != null) {
            // A new stream drops the queued PCM of the old position.
            self.closeAudioStream();
            self.openAudioStream() catch {
                self.audio_failed = true;
            };
        }
        self.audio_ended = false;
        self.audio_base_us = target_us;
        self.audio_produced_frames = 0;
        self.state.current_time_us = target_us;
        self.state.frame_pts_us = -1;
        self.state.ended = 0;
        self.state.frame_serial = 0;
        self.state.has_frame = 0;
        self.current_image = null;
        self.clearPrepared();
        self.last_produced_pts_us = -1;
        self.resync_pending = true;
    }

    /// Synchronously produces the frame for target_us (first frame, seek preview).
    pub fn update(self: *Video, target_us: i64) !bool {
        if (target_us < 0) return error.InvalidArgument;
        const effective_target = try self.updateAudio(target_us);
        var frame_target = std.math.add(i64, effective_target, self.av_sync_offset_us) catch
            if (self.av_sync_offset_us > 0) @as(i64, std.math.maxInt(i64)) else @as(i64, std.math.minInt(i64));
        frame_target = @max(0, frame_target);
        if (self.info.duration_us > 0) {
            frame_target = if (effective_target >= self.info.duration_us)
                self.info.duration_us
            else
                @min(frame_target, self.info.duration_us - 1);
        }
        self.state.current_time_us = effective_target;
        const outcome = self.produceBlocking(frame_target);
        self.state.prepare_time_us = outcome.elapsed_us;
        if (outcome.failed) |err| {
            self.captureVideoError();
            return err;
        }
        if (outcome.reached_end) {
            self.state.ended = 1;
            return false;
        }
        self.state.ended = 0;
        const decoded = outcome.frame orelse return false;
        self.last_produced_pts_us = decoded.pts_us;
        self.resync_pending = false;
        self.publish(decoded);
        return true;
    }

    /// Posts asynchronous frame production; the result is collected by
    /// schedule(), prepareNext(), or drainPreparation(). Never blocks.
    pub fn prepare(self: *Video, target_us: i64) !bool {
        if (target_us < 0) return error.InvalidArgument;
        const frame_target = if (self.info.duration_us > 0)
            @min(target_us, self.info.duration_us - 1)
        else
            target_us;
        self.worker_mutex.lockUncancelable(io);
        defer self.worker_mutex.unlock(io);
        if (self.worker_busy or self.worker_pending != null or self.worker_result != null) return false;
        // Every pooled frame is still on screen or held by a handle: skip this frame.
        const slot = self.freeSlot() orelse return false;
        try self.ensureWorkerLocked();
        self.worker_pending = .{
            .target_us = frame_target,
            .known_frame_serial = self.state.frame_serial,
            .known_prepared_serial = self.prepared_serial,
            .slot = slot,
        };
        self.worker_wake.signal(io);
        return true;
    }

    /// Waits for in-flight production and collects it.
    pub fn drainPreparation(self: *Video) void {
        self.worker_mutex.lockUncancelable(io);
        while (self.worker_busy or self.worker_pending != null) self.worker_done.waitUncancelable(io, &self.worker_mutex);
        self.worker_mutex.unlock(io);
        self.collectPrepared();
    }

    // Runs on the caller, which owns every retain and release. A free image is
    // unpublished and unreferenced, so the worker may write it exclusively.
    fn freeSlot(self: *Video) ?usize {
        for (self.frame_pool, 0..) |slot, index| {
            const value = slot orelse return index;
            if (value != self.current_image and value != self.prepared_image and value.ref_count == 1) return index;
        }
        return null;
    }

    fn ensureWorkerLocked(self: *Video) !void {
        if (self.worker != null) return;
        self.worker = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.OutOfMemory;
    }

    fn workerMain(self: *Video) void {
        while (true) {
            self.worker_mutex.lockUncancelable(io);
            while (self.worker_pending == null and !self.worker_quit) self.worker_wake.waitUncancelable(io, &self.worker_mutex);
            if (self.worker_quit) {
                self.worker_mutex.unlock(io);
                return;
            }
            const request = self.worker_pending.?;
            self.worker_pending = null;
            self.worker_busy = true;
            self.worker_mutex.unlock(io);

            const started = nowUs();
            var outcome = self.produceFrame(request);
            outcome.elapsed_us = elapsedSince(started);

            self.worker_mutex.lockUncancelable(io);
            self.worker_result = outcome;
            self.worker_busy = false;
            self.worker_done.broadcast(io);
            self.worker_mutex.unlock(io);
        }
    }

    // Runs on the worker thread. Touches only the decoder's video stream and
    // the thread-safe allocator; every input is snapshotted in the request.
    fn produceFrame(self: *Video, request: ProduceRequest) ProduceOutcome {
        var pixels: ?[*]const u8 = null;
        var width: u32 = 0;
        var height: u32 = 0;
        var stride: u32 = 0;
        var pts_us: i64 = -1;
        var serial: u64 = 0;
        const result = otv_decode_frame(self.decoder, request.target_us, &pixels, &width, &height, &stride, &pts_us, &serial);
        if (result == 1) return .{ .reached_end = true };
        if (result != 0 or pixels == null) return .{ .failed = error.DecodeFailed };
        if (serial == request.known_frame_serial or serial == request.known_prepared_serial) return .{};
        const required = @as(usize, stride) * height;
        const source = pixels.?[0..required];
        const slot = &self.frame_pool[request.slot];
        if (slot.*) |value| {
            if (value.width() == width and value.height() == height) {
                image.updatePixels(value, source, .{ .stride = stride }) catch |err| return .{ .failed = err };
                return .{ .frame = .{ .value = value, .pts_us = pts_us, .serial = serial } };
            }
            // Output geometry changed; the free image of the old size is replaced.
            value.deinit();
            slot.* = null;
        }
        const next = image.createFromRgba(self.allocator, source, width, height, stride) catch |err|
            return .{ .failed = err };
        slot.* = next;
        return .{ .frame = .{ .value = next, .pts_us = pts_us, .serial = serial } };
    }

    // Blocks the caller while the worker produces one frame.
    fn produceBlocking(self: *Video, target_us: i64) ProduceOutcome {
        self.worker_mutex.lockUncancelable(io);
        defer self.worker_mutex.unlock(io);
        // Discard any stale in-flight preparation first.
        self.worker_pending = null;
        while (self.worker_busy) self.worker_done.waitUncancelable(io, &self.worker_mutex);
        self.worker_result = null;
        const slot = self.freeSlot() orelse return .{};
        self.ensureWorkerLocked() catch return .{ .failed = error.OutOfMemory };
        self.worker_pending = .{
            .target_us = target_us,
            .known_frame_serial = if (self.current_image != null) self.state.frame_serial else std.math.maxInt(u64),
            .known_prepared_serial = self.prepared_serial,
            .slot = slot,
        };
        self.worker_wake.signal(io);
        while (self.worker_busy or self.worker_pending != null) self.worker_done.waitUncancelable(io, &self.worker_mutex);
        const outcome = self.worker_result orelse ProduceOutcome{};
        self.worker_result = null;
        return outcome;
    }

    // Moves a finished worker result into the prepared slot on the caller.
    fn collectPrepared(self: *Video) void {
        self.worker_mutex.lockUncancelable(io);
        const outcome = self.worker_result;
        self.worker_result = null;
        self.worker_mutex.unlock(io);
        const value = outcome orelse return;
        self.state.prepare_time_us = value.elapsed_us;
        if (value.failed != null) {
            self.captureVideoError();
            return;
        }
        const frame = value.frame orelse return;
        self.preparation_latency.add(value.elapsed_us);
        self.updateSyncLead();
        self.clearPrepared();
        self.prepared_image = frame.value;
        self.prepared_serial = frame.serial;
        self.state.prepared_pts_us = frame.pts_us;
        self.last_produced_pts_us = frame.pts_us;
    }

    // Cancels pending work and waits out in-flight production; the caller may
    // then mutate the decoder's video stream safely.
    fn quiesceWorker(self: *Video) void {
        self.worker_mutex.lockUncancelable(io);
        defer self.worker_mutex.unlock(io);
        self.worker_pending = null;
        while (self.worker_busy) self.worker_done.waitUncancelable(io, &self.worker_mutex);
        self.worker_result = null;
    }

    fn captureVideoError(self: *Video) void {
        const message = std.mem.span(otv_stream_error(self.decoder, 0));
        const length = @min(message.len, self.last_error_buf.len);
        @memcpy(self.last_error_buf[0..length], message[0..length]);
        self.last_error_len = length;
    }

    /// Presents the prepared frame once the clock reaches its deadline, or drops it when stale.
    pub fn schedule(self: *Video, fallback_time_us: i64, presentation_interval_us: u32) !void {
        if (fallback_time_us < 0 or presentation_interval_us == 0) return error.InvalidArgument;
        self.state.current_time_us = try self.updateAudio(fallback_time_us);
        self.collectPrepared();
        self.updateSyncLead();
        const prepared = self.prepared_image orelse return;
        const prepared_pts = self.state.prepared_pts_us;
        if (prepared_pts < self.state.current_time_us - presentation_interval_us) {
            self.clearPrepared();
            self.resync_pending = true;
            return;
        }
        const deadline = prepared_pts - self.av_sync_offset_us;
        if (self.state.current_time_us < deadline) return;
        self.prepared_image = null;
        self.publish(.{ .value = prepared, .pts_us = prepared_pts, .serial = self.prepared_serial });
        self.prepared_serial = 0;
        self.state.prepared_pts_us = -1;
    }

    pub fn prepareNext(self: *Video, presentation_interval_us: u32) !bool {
        if (presentation_interval_us == 0) return error.InvalidArgument;
        self.collectPrepared();
        if (self.prepared_image != null) return false;
        self.updateSyncLead();
        // Production marches through the source deterministically: one
        // presentation step per produced frame, independent of scheduling
        // jitter. The half-step margin makes the at-or-before frame selection
        // reach the next frame across timestamp rounding. Only a resync
        // (start, seek, reconfiguration, dropped frame) consults the clock.
        const interval: i64 = presentation_interval_us;
        const source_interval: i64 = if (self.info.fps_num > 0)
            @intCast((@as(u64, 1_000_000) * self.info.fps_den + self.info.fps_num - 1) / self.info.fps_num)
        else
            interval;
        const target = if (self.resync_pending or self.last_produced_pts_us < 0)
            self.state.current_time_us + @as(i64, self.state.sync_lead_us) + interval + self.av_sync_offset_us
        else
            self.last_produced_pts_us + @max(interval, source_interval) + @divTrunc(source_interval, 2);
        self.resync_pending = false;
        return self.prepare(@max(0, target));
    }

    fn publish(self: *Video, decoded: PreparedFrame) void {
        self.current_image = decoded.value;
        self.state.frame_pts_us = decoded.pts_us;
        self.state.frame_serial = decoded.serial;
        self.state.has_frame = 1;
        self.published += 1;
    }

    fn clearPrepared(self: *Video) void {
        self.prepared_image = null;
        self.prepared_serial = 0;
        self.state.prepared_pts_us = -1;
    }

    fn updateSyncLead(self: *Video) void {
        self.state.sync_lead_us = self.preparation_latency.maximum();
    }

    fn resetScheduler(self: *Video) void {
        self.clearPrepared();
        self.last_produced_pts_us = -1;
        self.resync_pending = true;
        self.preparation_latency.reset();
        self.state.sync_lead_us = 0;
    }

    pub fn getState(self: *Video) State {
        if (self.audioClockActive()) self.state.current_time_us = self.audioTimeUs();
        self.refreshAudioState();
        return self.state;
    }

    fn decodeAudio(self: *Video, samples: []f32, capacity_frames: u32) !u32 {
        if (self.info.has_audio == 0) return 0;
        const required = @as(usize, capacity_frames) * self.info.audio_channels;
        if (samples.len < required) return error.InvalidArgument;
        var frames: u32 = 0;
        if (otv_read_audio(self.decoder, if (samples.len == 0) null else samples.ptr, capacity_frames, &frames) < 0) {
            return error.DecodeFailed;
        }
        return frames;
    }

    pub fn readAudio(self: *Video, samples: []f32, capacity_frames: u32) !u32 {
        if (self.audio_engine != null) return error.InvalidArgument;
        return self.decodeAudio(samples, capacity_frames);
    }

    fn queuedAudioFrames(stats: audio.StreamStats) u32 {
        const received = stats.bytes_received / (2 * @sizeOf(f32));
        return @intCast(@min(received -| stats.frames_played, std.math.maxInt(u32)));
    }

    /// Decodes and queues up to max_frames of PCM, bounded by the queue capacity.
    pub fn refillAudio(self: *Video, max_frames: u32) !u32 {
        const engine = self.audio_engine orelse return 0;
        const buffer = self.audio_buffer orelse return 0;
        if (self.audio_ended or self.audio_failed or max_frames == 0) return 0;
        const stats = self.audioStats() orelse return error.DecodeFailed;
        const writable = audio_capacity_frames -| queuedAudioFrames(stats);
        const requested = @min(max_frames, @min(writable, audio_decode_frames));
        if (requested == 0) return 0;
        const decoded = try self.decodeAudio(buffer, requested);
        if (decoded == 0) {
            if (audio.endStream(engine, self.audio_stream) != audio.Status.ok) return error.DecodeFailed;
            self.audio_ended = true;
            return 0;
        }
        const bytes = std.mem.sliceAsBytes(buffer[0 .. @as(usize, decoded) * 2]);
        // The queue bound keeps writes within the stream's input capacity.
        const written = audio.writeStream(engine, self.audio_stream, bytes.ptr, @intCast(bytes.len));
        if (written != @as(i32, @intCast(bytes.len))) return error.DecodeFailed;
        self.audio_produced_frames += decoded;
        return decoded;
    }

    fn audioTimeUs(self: *Video) i64 {
        const stats = self.audioStats() orelse return self.audio_base_us;
        return self.audio_base_us + @as(i64, @intCast(stats.frames_played * 1_000_000 / audio_sample_rate));
    }

    // The audio clock leads while playback wants it and the stream has not drained.
    fn audioClockActive(self: *Video) bool {
        if (self.audio_engine == null or !self.wants_playback or self.audio_failed) return false;
        const stats = self.audioStats() orelse return false;
        return stats.state != audio.StreamState.ended;
    }

    fn refreshAudioState(self: *Video) void {
        self.state.playing = @intFromBool(self.wants_playback);
        self.state.audio_ended = @intFromBool(self.audio_ended);
        self.state.audio_failed = @intFromBool(self.audio_failed);
        const stats = self.audioStats() orelse {
            self.state.buffering = 0;
            self.state.audio_active = 0;
            self.state.audio_queued_frames = 0;
            self.state.audio_consumed_frames = 0;
            self.state.audio_produced_frames = 0;
            self.state.audio_underruns = 0;
            return;
        };
        const active = self.audioClockActive();
        const audio_playing = stats.state == audio.StreamState.playing and self.mixer_running;
        self.state.audio_active = @intFromBool(active and audio_playing);
        self.state.buffering = @intFromBool(active and !audio_playing);
        self.state.audio_queued_frames = queuedAudioFrames(stats);
        self.state.audio_consumed_frames = stats.frames_played;
        self.state.audio_produced_frames = self.audio_produced_frames;
        self.state.audio_underruns = stats.underruns;
    }

    fn setMixerRunning(self: *Video, running: bool) void {
        const engine = self.audio_engine orelse return;
        if (running) _ = audio.startMixer(engine) else audio.suspendMixer(engine);
        self.mixer_running = running;
    }

    fn updateAudio(self: *Video, fallback_time_us: i64) !i64 {
        if (self.audio_engine == null) {
            self.refreshAudioState();
            return fallback_time_us;
        }
        const device_status = self.audio_device_status.load(.acquire);
        if (device_status != 0 and self.audio_start_thread != null) {
            self.audio_start_thread.?.join();
            self.audio_start_thread = null;
            // Starting the device starts the mixer; a pause meanwhile still applies.
            self.mixer_running = device_status > 0;
        }
        if (device_status < 0) self.audio_failed = true;
        if (self.audio_offline or device_status > 0) {
            const wanted = self.wants_playback and !self.audio_failed;
            if (wanted != self.mixer_running) self.setMixerRunning(wanted);
        }
        if (!self.wants_playback or self.audio_failed) {
            self.refreshAudioState();
            return fallback_time_us;
        }
        _ = try self.refillAudio(audio_decode_frames);
        if (self.audioStats()) |stats| {
            if (stats.state == audio.StreamState.failed) self.audio_failed = true;
        }
        self.refreshAudioState();
        return if (self.audioClockActive()) self.audioTimeUs() else fallback_time_us;
    }

    pub fn play(self: *Video) void {
        self.wants_playback = true;
        self.state.ended = 0;
        if (self.audio_engine != null and !self.audio_offline and !self.audio_failed and
            self.audio_device_status.load(.acquire) == 0 and self.audio_start_thread == null)
        {
            // Device startup can block, so it runs off the caller.
            self.audio_start_thread = std.Thread.spawn(.{}, startAudioDevice, .{self}) catch null;
            if (self.audio_start_thread == null) self.audio_device_status.store(-1, .release);
        }
        self.refreshAudioState();
    }

    fn startAudioDevice(self: *Video) void {
        const status = audio.start(self.audio_engine.?, null);
        self.audio_device_status.store(if (status == audio.Status.ok) 1 else -1, .release);
    }

    // A suspended mixer stops reading the stream, so the audio clock holds its position.
    pub fn pause(self: *Video) void {
        if (self.audio_engine != null and (self.audio_offline or self.audio_device_status.load(.acquire) > 0)) {
            self.setMixerRunning(false);
        }
        self.wants_playback = false;
        self.refreshAudioState();
    }

    pub fn setMuted(self: *Video, muted: bool) !void {
        self.muted = muted;
        try self.applyGain();
    }

    pub fn setVolume(self: *Video, volume: f32) !void {
        if (!std.math.isFinite(volume) or volume < 0) return error.InvalidArgument;
        self.volume = volume;
        try self.applyGain();
    }

    fn applyGain(self: *Video) !void {
        const engine = self.audio_engine orelse return;
        if (audio.setMasterVolume(engine, if (self.muted) 0 else self.volume) != audio.Status.ok) return error.DecodeFailed;
    }

    pub fn setAvSyncOffset(self: *Video, offset_us: i64) void {
        self.av_sync_offset_us = offset_us;
        self.quiesceWorker();
        self.clearPrepared();
        self.resync_pending = true;
    }

    /// Tests mix the engine manually instead of opening a device.
    pub fn setAudioOffline(self: *Video, offline: bool) void {
        self.audio_offline = offline;
    }

    pub fn lastError(self: *const Video) []const u8 {
        if (self.last_error_len > 0) return self.last_error_buf[0..self.last_error_len];
        return std.mem.span(otv_last_error(self.decoder));
    }
};

pub const PlayerState = struct {
    current_time_us: i64,
    frame_pts_us: i64,
    playing: bool,
    ended: bool,
    buffering: bool,
    audio: bool,
    has_frame: bool,
    failed: bool,
};

/// Playback of one video scene node: a media clock, looping, and output geometry.
/// Each paint calls frame(), which advances playback and returns the image to draw.
pub const Player = struct {
    allocator: Allocator,
    video: *Video,
    playing: bool = false,
    loop: bool = false,
    ended: bool = false,
    failed: bool = false,
    // Media position when the wall clock last started or stopped.
    position_us: i64 = 0,
    clock_start_us: i64 = 0,
    needs_update: bool = true,
    max_fps: u32 = 30,

    pub fn open(allocator: Allocator, path: []const u8, error_out: []u8) !*Player {
        const value = try Video.open(allocator, path, false, error_out);
        errdefer value.deinit();
        const player = try allocator.create(Player);
        player.* = .{ .allocator = allocator, .video = value };
        return player;
    }

    pub fn deinit(self: *Player) void {
        self.video.deinit();
        self.allocator.destroy(self);
    }

    fn duration(self: *const Player) i64 {
        return self.video.info.duration_us;
    }

    fn intervalUs(self: *const Player) u32 {
        const info = self.video.info;
        const source_fps: f64 = if (info.fps_num > 0 and info.fps_den > 0) @as(f64, @floatFromInt(info.fps_num)) / @as(f64, @floatFromInt(info.fps_den)) else 0;
        const fps = if (source_fps > 0) @min(source_fps, @as(f64, @floatFromInt(self.max_fps))) else @as(f64, @floatFromInt(self.max_fps));
        return @intFromFloat(@max(1, @round(1_000_000 / fps)));
    }

    fn normalize(self: *const Player, time_us: i64) i64 {
        const value = @max(0, time_us);
        const total = self.duration();
        if (total <= 0) return value;
        return if (self.loop) @mod(value, total) else @min(value, total);
    }

    fn wallTime(self: *const Player) i64 {
        return self.position_us + (nowUs() - self.clock_start_us);
    }

    pub fn currentTime(self: *Player) i64 {
        if (!self.playing) return self.position_us;
        const state = self.video.getState();
        if (state.audio_active != 0 or state.buffering != 0) return state.current_time_us;
        return self.normalize(self.wallTime());
    }

    pub fn snapshot(self: *Player) PlayerState {
        const time = self.currentTime();
        const state = self.video.getState();
        return .{
            .current_time_us = time,
            .frame_pts_us = state.frame_pts_us,
            .playing = self.playing,
            .ended = self.ended,
            .buffering = self.playing and state.buffering != 0,
            .audio = self.playing and state.audio_active != 0,
            .has_frame = self.video.current_image != null,
            .failed = self.failed,
        };
    }

    pub fn play(self: *Player) !void {
        if (self.playing or self.failed) return;
        if (self.ended and !self.loop) try self.seek(0);
        self.playing = true;
        self.ended = false;
        self.clock_start_us = nowUs();
        self.video.play();
    }

    pub fn pause(self: *Player) !void {
        if (!self.playing) return;
        self.position_us = self.currentTime();
        self.playing = false;
        self.video.pause();
    }

    pub fn seek(self: *Player, time_us: i64) !void {
        const target = self.normalize(time_us);
        self.video.seek(target) catch {
            self.fail();
            return;
        };
        self.position_us = target;
        self.clock_start_us = nowUs();
        self.ended = false;
        self.needs_update = true;
    }

    pub fn setLoop(self: *Player, loop: bool) !void {
        self.loop = loop;
    }

    pub fn setMuted(self: *Player, muted: bool) !void {
        try self.video.setMuted(muted);
    }

    pub fn setVolume(self: *Player, volume: f32) !void {
        try self.video.setVolume(volume);
    }

    pub fn setAvSyncOffset(self: *Player, offset_us: i64) !void {
        self.video.setAvSyncOffset(offset_us);
    }

    fn finish(self: *Player) void {
        self.position_us = self.duration();
        self.playing = false;
        self.ended = true;
        self.video.pause();
    }

    fn fail(self: *Player) void {
        self.failed = true;
        self.playing = false;
        self.video.pause();
    }

    /// Reaching the end loops or ends playback; returns whether playback restarted.
    fn reachEnd(self: *Player, media_us: i64) bool {
        const total = self.duration();
        if (total <= 0 or media_us < total) return false;
        if (self.loop) {
            self.seek(0) catch {};
            return !self.failed;
        }
        self.finish();
        return false;
    }

    /// Advances playback to now and returns the current frame for a decode target of
    /// width x height pixels. Decode failures stop playback and keep the last frame.
    pub fn frame(self: *Player, width: u32, height: u32, cover: bool) ?*image.Image {
        if (self.failed) return self.video.current_image;
        self.advance(width, height, cover) catch self.fail();
        return self.video.current_image;
    }

    fn advance(self: *Player, width: u32, height: u32, cover: bool) !void {
        if (width != self.video.output_width or height != self.video.output_height or cover != self.video.output_cover) {
            try self.video.configureOutput(width, height, cover);
            self.needs_update = true;
        }
        if (self.needs_update or self.video.current_image == null) {
            _ = try self.video.update(self.currentTime());
            self.needs_update = false;
        }
        if (!self.playing) return;
        const interval = self.intervalUs();
        const wall = self.wallTime();
        const state = self.video.getState();
        const audio_clock = state.audio_active != 0 or state.buffering != 0;
        if (!audio_clock and self.reachEnd(wall)) return self.advance(width, height, cover);
        if (!self.playing) return;
        try self.video.schedule(self.normalize(wall), interval);
        if (audio_clock and self.reachEnd(self.video.state.current_time_us)) return self.advance(width, height, cover);
        if (!self.playing) return;
        if (self.video.state.prepared_pts_us < 0) _ = try self.video.prepareNext(interval);
    }

    pub fn lastError(self: *const Player) []const u8 {
        return self.video.lastError();
    }
};
