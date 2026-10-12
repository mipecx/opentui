import type { OptimizedBuffer } from "../buffer.js"
import { Renderable, type RenderableOptions } from "../Renderable.js"
import type { RenderContext } from "../types.js"
import type { NativeVideoState } from "../zig.js"
import type { ImageFit } from "./Image.js"

export interface VideoMetadata {
  width: number
  height: number
  fps: number
  duration: number
  hasAudio: boolean
}

export interface VideoRenderableOptions extends RenderableOptions<VideoRenderable> {
  /** Path of an MP4 (H.264/AAC) file. */
  source?: string
  fit?: ImageFit
  autoplay?: boolean
  loop?: boolean
  muted?: boolean
  volume?: number
  /** Positive values show frames earlier relative to the audio. */
  avSyncOffsetMs?: number
  onReady?: (metadata: VideoMetadata) => void
  onError?: (error: Error) => void
  onEnd?: () => void
  onPlay?: () => void
  onPause?: () => void
  onSeek?: (time: number) => void
  onTimeUpdate?: (time: number) => void
}

function validateVolume(value: number): void {
  if (!Number.isFinite(value) || value < 0) throw new RangeError("volume must be finite and non-negative")
}

function toMicroseconds(seconds: number, label: string): bigint {
  const value = Math.round(seconds * 1_000_000)
  if (!Number.isFinite(seconds) || !Number.isSafeInteger(value)) throw new RangeError(`${label} must be finite`)
  return BigInt(value)
}

/**
 * Plays a video file in a native scene node. Decoding, the media clock, and frame drawing stay native;
 * this wrapper sends control calls and reads playback state once per frame while playing.
 */
export class VideoRenderable extends Renderable {
  static override readonly nativeIntegration = this.defineNativeIntegration({
    kind: "video",
    body: { native: this.prototype.renderSelf, buffered: true },
    lifecycle: {
      update: {
        idle: this.prototype.onUpdate,
        active: (renderable) => (renderable as VideoRenderable)._wantsPlayback,
      },
    },
    bufferComposition: "native",
    construction: "prototype",
  })

  private _source: string | undefined
  private _fit: ImageFit
  private _loop: boolean
  private _muted: boolean
  private _volume: number
  private _avSyncOffsetMs: number
  private _metadata: VideoMetadata | null = null
  private _playing = false
  private _ended = false
  private _mediaTime = 0
  public onReady?: (metadata: VideoMetadata) => void
  public onError?: (error: Error) => void
  public onEnd?: () => void
  public onPlay?: () => void
  public onPause?: () => void
  public onSeek?: (time: number) => void
  public onTimeUpdate?: (time: number) => void

  constructor(ctx: RenderContext, options: VideoRenderableOptions) {
    super(ctx, options)
    try {
      this._fit = options.fit ?? "fit"
      this._loop = options.loop ?? false
      this._muted = options.muted ?? false
      this._volume = options.volume ?? 1
      validateVolume(this._volume)
      this._avSyncOffsetMs = options.avSyncOffsetMs ?? 0
      toMicroseconds(this._avSyncOffsetMs / 1000, "avSyncOffsetMs")
      this.onReady = options.onReady
      this.onError = options.onError
      this.onEnd = options.onEnd
      this.onPlay = options.onPlay
      this.onPause = options.onPause
      this.onSeek = options.onSeek
      this.onTimeUpdate = options.onTimeUpdate
      this._playing = options.autoplay ?? false
      this.setNativeSceneVideo()
      if (options.source !== undefined) this.source = options.source
    } catch (error) {
      this.abortConstruction(error, () => this.destroySelf())
    }
  }

  /** @internal */
  get _wantsPlayback(): boolean {
    return this._playing && this._metadata !== null
  }

  public get source(): string | undefined {
    return this._source
  }

  /** Opens a new source; playback intent carries over to it. */
  public set source(value: string | null | undefined) {
    value ??= undefined
    if (value === this._source || this.isDestroyed) return
    this._source = value
    this._metadata = null
    this._ended = false
    this._mediaTime = 0
    const native = this.native()
    try {
      const info = native.lib.videoOpen(native.context, native.node, value ?? "")
      if (value === undefined) return
      this._metadata = {
        width: info.width,
        height: info.height,
        fps: info.fpsDen > 0 ? info.fpsNum / info.fpsDen : 0,
        duration: Number(info.durationUs) / 1_000_000,
        hasAudio: info.hasAudio,
      }
      native.lib.videoSetLoop(native.context, native.node, this._loop)
      native.lib.videoSetMuted(native.context, native.node, this._muted)
      native.lib.videoSetVolume(native.context, native.node, this._volume)
      native.lib.videoSetAvSyncOffset(
        native.context,
        native.node,
        toMicroseconds(this._avSyncOffsetMs / 1000, "avSyncOffsetMs"),
      )
      if (this._playing) native.lib.videoCall(native.context, native.node, "ot_video_play")
      const metadata = { ...this._metadata }
      // Frameworks assign handlers after the source; report the open once they are set.
      this.afterOpen(value, () => this.onReady?.(metadata))
    } catch (error) {
      this._playing = false
      const detail = this.errorDetail("")
      this.afterOpen(value, () => this.reportError(error, detail))
    } finally {
      this.syncPlayback()
      this.requestRender()
    }
  }

  public get fit(): ImageFit {
    return this._fit
  }

  public set fit(value: ImageFit | null | undefined) {
    const next = value ?? "fit"
    if (this._fit === next || this.isDestroyed) return
    this.setNativeSceneVideo(next)
    this._fit = next
    this.requestRender()
  }

  public get loop(): boolean {
    return this._loop
  }

  public set loop(value: boolean | null | undefined) {
    const next = value ?? false
    if (this._loop === next || this.isDestroyed) return
    this._loop = next
    this.control((native) => native.lib.videoSetLoop(native.context, native.node, next))
  }

  public get muted(): boolean {
    return this._muted
  }

  public set muted(value: boolean | null | undefined) {
    const next = value ?? false
    if (this._muted === next || this.isDestroyed) return
    this._muted = next
    this.control((native) => native.lib.videoSetMuted(native.context, native.node, next))
  }

  public get volume(): number {
    return this._volume
  }

  public set volume(value: number | null | undefined) {
    const next = value ?? 1
    validateVolume(next)
    if (this._volume === next || this.isDestroyed) return
    this._volume = next
    this.control((native) => native.lib.videoSetVolume(native.context, native.node, next))
  }

  public get avSyncOffsetMs(): number {
    return this._avSyncOffsetMs
  }

  public set avSyncOffsetMs(value: number | null | undefined) {
    const next = value ?? 0
    const offset = toMicroseconds(next / 1000, "avSyncOffsetMs")
    if (this._avSyncOffsetMs === next || this.isDestroyed) return
    this._avSyncOffsetMs = next
    this.control((native) => native.lib.videoSetAvSyncOffset(native.context, native.node, offset))
  }

  public get ready(): boolean {
    return this._metadata !== null
  }

  public get videoMetadata(): Readonly<VideoMetadata> | null {
    return this._metadata ? { ...this._metadata } : null
  }

  public get playing(): boolean {
    return this._playing && !this._ended
  }

  public get paused(): boolean {
    return !this._playing
  }

  public get ended(): boolean {
    return this._ended
  }

  public get duration(): number {
    return this._metadata?.duration ?? 0
  }

  public get durationMs(): number {
    return this.duration * 1000
  }

  public get currentTime(): number {
    if (!this._metadata || this.isDestroyed) return this._mediaTime
    return Number(this.readState().currentTimeUs) / 1_000_000
  }

  /** Seeks; a nullish write is ignored. */
  public set currentTime(value: number | null | undefined) {
    if (value == null) return
    this.seek(value)
  }

  public get currentTimeMs(): number {
    return this.currentTime * 1000
  }

  public play(): void {
    if ((this._playing && !this._ended) || this.isDestroyed) return
    this._playing = true
    this._ended = false
    if (!this._metadata) return
    this.control((native) => native.lib.videoCall(native.context, native.node, "ot_video_play"))
    if (this._playing) this.onPlay?.()
  }

  public resume(): void {
    this.play()
  }

  public pause(): void {
    if (!this._playing || this.isDestroyed) return
    this._playing = false
    if (!this._metadata) return
    this.control((native) => native.lib.videoCall(native.context, native.node, "ot_video_pause"))
    this._mediaTime = this.currentTime
    this.onPause?.()
    this.onTimeUpdate?.(this._mediaTime)
  }

  public toggle(): void {
    if (this._playing && !this._ended) this.pause()
    else this.play()
  }

  public seek(time: number): void {
    const target = toMicroseconds(Math.max(0, time), "Video time")
    if (!this._metadata || this.isDestroyed) return
    this._ended = false
    this.control((native) => native.lib.videoSeek(native.context, native.node, target))
    this._mediaTime = this.currentTime
    this.onSeek?.(this._mediaTime)
    this.onTimeUpdate?.(this._mediaTime)
  }

  public seekBy(delta: number): void {
    if (!Number.isFinite(delta)) throw new RangeError("Video seek delta must be finite")
    this.seek(this.currentTime + delta)
  }

  public seekToMs(milliseconds: number): void {
    if (!Number.isFinite(milliseconds)) throw new RangeError("Video time must be finite")
    this.seek(milliseconds / 1000)
  }

  protected override createFrameBuffer(): void {
    const previous = this.frameBuffer
    super.createFrameBuffer()
    // Base construction can allocate before Video options are initialized.
    if (this._fit === undefined || this.frameBuffer === previous) return
    this.setNativeSceneVideo()
  }

  // Native code draws the frame; this keeps the body native.
  protected renderSelf(_buffer: OptimizedBuffer): void {}

  protected override onUpdate(deltaTime: number): void {
    super.onUpdate(deltaTime)
    if (!this._wantsPlayback || this.isDestroyed) return
    const state = this.readState()
    if (state.failed) {
      this._playing = false
      this.reportError(new Error(this.errorDetail("Video playback failed")))
      this.syncPlayback()
      return
    }
    this._mediaTime = Number(state.currentTimeUs) / 1_000_000
    this.onTimeUpdate?.(this._mediaTime)
    if (state.ended) {
      this._playing = false
      this._ended = true
      this.syncPlayback()
      this.onEnd?.()
    }
  }

  private native() {
    return this._ctx.nativeScene.videoNode(this)
  }

  private readState(): NativeVideoState {
    const native = this.native()
    return native.lib.videoGetState(native.context, native.node)
  }

  private errorDetail(fallback: string): string {
    try {
      const native = this.native()
      return native.lib.videoGetError(native.context, native.node) || fallback
    } catch {
      return fallback
    }
  }

  private control(call: (native: ReturnType<VideoRenderable["native"]>) => void): void {
    try {
      call(this.native())
    } catch (error) {
      this._playing = false
      this.reportError(error)
    } finally {
      this.syncPlayback()
      this.requestRender()
    }
  }

  // Playback keeps the renderer painting and the per-frame state hook active.
  private syncPlayback(): void {
    if (this.isDestroyed) return
    const active = this._wantsPlayback
    if (this.live !== active) this.live = active
    this.refreshNativeSceneHooks()
  }

  private setNativeSceneVideo(fit: ImageFit = this._fit): void {
    this._ctx.nativeScene.setVideo(this, fit, this.buffered ? this.frameBuffer : null)
  }

  private afterOpen(source: string | undefined, report: () => void): void {
    queueMicrotask(() => {
      if (this._source === source && !this.isDestroyed) report()
    })
  }

  private reportError(error: unknown, detail = this.errorDetail("")): void {
    const value = error instanceof Error ? error : new Error(String(error))
    this.onError?.(detail && !value.message.includes(detail) ? new Error(`${value.message}: ${detail}`) : value)
  }

  protected destroySelf(): void {
    this._playing = false
    this.runCleanup((run) => {
      run(() => {
        if (this.live) this.live = false
      })
      run(() => super.destroySelf())
    })
  }
}
