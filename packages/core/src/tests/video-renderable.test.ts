import { fileURLToPath } from "node:url"

import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { VideoRenderable, type VideoMetadata } from "../renderables/Video.js"
import { createTestRenderer, type TestRenderer, type TestRendererSetup } from "../testing/test-renderer.js"

const FIXTURE = fileURLToPath(new URL("./fixtures/video/testsrc-160x90-24fps-2s.mp4", import.meta.url))
const MISSING = fileURLToPath(new URL("./fixtures/video/missing.mp4", import.meta.url))

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

describe("VideoRenderable", () => {
  let setup: TestRendererSetup
  let renderer: TestRenderer

  beforeEach(async () => {
    setup = await createTestRenderer({ width: 20, height: 6 })
    renderer = setup.renderer
  })

  afterEach(() => {
    renderer.destroy()
  })

  test("opens metadata and paints the first frame natively while paused", async () => {
    let ready: VideoMetadata | undefined
    const video = new VideoRenderable(renderer, {
      source: FIXTURE,
      width: 20,
      height: 6,
      onReady: (metadata) => (ready = metadata),
    })
    renderer.root.add(video)
    expect(video.ready).toBe(true)
    expect(ready).toBeUndefined()
    await Promise.resolve()
    expect(ready).toEqual({ width: 160, height: 90, fps: 24, duration: expect.any(Number), hasAudio: true })
    expect(video.duration).toBeGreaterThan(1.9)
    expect(video.paused).toBe(true)
    expect(video.live).toBe(false)
    await setup.renderOnce()
    expect(setup.captureCharFrame().trim().length).toBeGreaterThan(0)
  })

  test("play keeps the renderer live and pause holds the position", async () => {
    const video = new VideoRenderable(renderer, { source: FIXTURE, width: 20, height: 6, muted: true })
    renderer.root.add(video)
    let played = 0
    video.onPlay = () => played++
    video.play()
    expect(played).toBe(1)
    expect(video.playing).toBe(true)
    expect(video.live).toBe(true)
    for (let index = 0; index < 5; index++) {
      await sleep(20)
      await setup.renderOnce()
    }
    video.pause()
    expect(video.live).toBe(false)
    const position = video.currentTime
    await sleep(40)
    await setup.renderOnce()
    expect(video.currentTime).toBe(position)
  })

  test("seek reports the target and reaching the end fires onEnd", async () => {
    const seeks: number[] = []
    let ended = 0
    const video = new VideoRenderable(renderer, {
      source: FIXTURE,
      width: 20,
      height: 6,
      muted: true,
      onSeek: (time) => seeks.push(time),
      onEnd: () => ended++,
    })
    renderer.root.add(video)
    video.seek(1)
    expect(seeks).toEqual([1])
    expect(video.currentTime).toBe(1)
    video.seek(video.duration - 0.01)
    video.play()
    for (let index = 0; index < 20 && ended === 0; index++) {
      await sleep(20)
      await setup.renderOnce()
    }
    expect(ended).toBe(1)
    expect(video.ended).toBe(true)
    expect(video.live).toBe(false)
  })

  test("open failures report the native detail", async () => {
    const errors: Error[] = []
    const video = new VideoRenderable(renderer, { source: MISSING, onError: (error) => errors.push(error) })
    expect(video.ready).toBe(false)
    await Promise.resolve()
    expect(errors).toHaveLength(1)
    expect(errors[0].message).toContain("ot_video_open")
    expect(errors[0].message.length).toBeGreaterThan("ot_video_open failed: VideoFailed".length)
  })

  test("replacing the source keeps playback intent and destroy releases the player", async () => {
    const video = new VideoRenderable(renderer, { source: FIXTURE, autoplay: true, muted: true })
    renderer.root.add(video)
    expect(video.live).toBe(true)
    video.source = undefined
    expect(video.ready).toBe(false)
    expect(video.live).toBe(false)
    video.source = FIXTURE
    expect(video.live).toBe(true)
    await setup.renderOnce()
    video.destroy()
    await setup.renderOnce()
  })
})
