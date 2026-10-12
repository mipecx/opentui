#!/usr/bin/env bun

import {
  BoxRenderable,
  CliRenderEvents,
  TextRenderable,
  VideoRenderable,
  createCliRenderer,
  type CliRenderer,
  type ImageFit,
  type KeyEvent,
} from "@opentui/core"
import { setupCommonDemoKeys } from "./lib/standalone-keys.js"

// @ts-ignore Bun embeds imported assets and returns their runtime paths.
import dragonPath from "./assets/dragon.mp4" with { type: "file" }

const FITS: ImageFit[] = ["fit", "cover", "fill"]

let root: BoxRenderable | null = null
let video: VideoRenderable | null = null
let status: TextRenderable | null = null
let keyListener: ((key: KeyEvent) => void) | null = null
let rendererDestroyHandler: (() => void) | null = null
let message = "Ready"

function formatTime(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds))
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`
}

function updateStatus(): void {
  if (!status || !video) return
  const state = video.ended ? "ended" : video.playing ? "playing" : "paused"
  status.content = `${state} ${formatTime(video.currentTime)} / ${formatTime(video.duration)} | fit ${video.fit} | ${
    video.muted ? "muted" : `volume ${Math.round(video.volume * 100)}%`
  } | loop ${video.loop ? "on" : "off"} | ${message}`
}

export async function run(renderer: CliRenderer): Promise<void> {
  rendererDestroyHandler = () => destroy(renderer)
  renderer.on(CliRenderEvents.DESTROY, rendererDestroyHandler)
  renderer.start()
  const source = process.argv.slice(2).find((argument) => !argument.startsWith("-")) ?? (dragonPath as string)

  root = new BoxRenderable(renderer, { id: "video-demo", width: "100%", height: "100%", flexDirection: "column" })
  video = new VideoRenderable(renderer, {
    id: "video-demo-player",
    source,
    width: "100%",
    flexGrow: 1,
    minHeight: 0,
    autoplay: true,
    loop: true,
    onError: (error) => {
      message = error.message
      updateStatus()
    },
    onTimeUpdate: updateStatus,
    onEnd: updateStatus,
  })
  status = new TextRenderable(renderer, { id: "video-demo-status", width: "100%", flexShrink: 0, fg: "#c7d8e2" })
  const help = new TextRenderable(renderer, {
    id: "video-demo-help",
    width: "100%",
    flexShrink: 0,
    fg: "#7f8c99",
    content: "Space play/pause | ←/→ seek 5s | ↑/↓ volume | M mute | L loop | F fit | Home restart",
  })
  root.add(video)
  root.add(status)
  root.add(help)
  renderer.root.add(root)

  keyListener = (key: KeyEvent) => {
    if (!video) return
    if (key.name === "space") video.toggle()
    else if (key.name === "left") video.seekBy(-5)
    else if (key.name === "right") video.seekBy(5)
    else if (key.name === "up") video.volume = Math.min(2, video.volume + 0.1)
    else if (key.name === "down") video.volume = Math.max(0, video.volume - 0.1)
    else if (key.name === "m") video.muted = !video.muted
    else if (key.name === "l") video.loop = !video.loop
    else if (key.name === "f") video.fit = FITS[(FITS.indexOf(video.fit) + 1) % FITS.length]
    else if (key.name === "home") video.seek(0)
    else return
    updateStatus()
  }
  renderer.keyInput.on("keypress", keyListener)
  updateStatus()
}

export function destroy(renderer: CliRenderer): void {
  if (rendererDestroyHandler) renderer.off(CliRenderEvents.DESTROY, rendererDestroyHandler)
  rendererDestroyHandler = null
  if (keyListener) renderer.keyInput.off("keypress", keyListener)
  keyListener = null
  root?.destroyRecursively()
  root = null
  video = null
  status = null
  message = "Ready"
}

if (import.meta.main) {
  const renderer = await createCliRenderer({ exitOnCtrlC: true })
  await run(renderer)
  setupCommonDemoKeys(renderer)
}
