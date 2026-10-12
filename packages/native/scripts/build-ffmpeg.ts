import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { availableParallelism } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

// Builds the minimal static FFmpeg that native video links. See src/vendor/ffmpeg/README.md.
const VERSION = "8.1.1"
const SHA256 = "b6863adde98898f42602017462871b5f6333e65aec803fdd7a6308639c52edf3"
const URL = `https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz`
const ZLIB_VERSION = "1.3.1"
const ZLIB_SHA256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
const ZLIB_URL = `https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz`
const BUILD_REVISION = "1"
// Must match the macOS minimum of the Zig-built library so the static FFmpeg
// objects never carry a newer availability floor than the final link.
const MACOS_VERSION_MIN = "13.0"
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const cache = join(root, ".cache", "ffmpeg")
const archive = join(cache, "downloads", `ffmpeg-${VERSION}.tar.xz`)
const source = join(cache, "sources", `ffmpeg-${VERSION}`)
const zlibArchive = join(cache, "downloads", `zlib-${ZLIB_VERSION}.tar.gz`)
const zlibSource = join(cache, "sources", `zlib-${ZLIB_VERSION}`)

interface Target {
  // Matches the output names in build.zig.
  name: string
  zig: string
  arch: "x86_64" | "aarch64"
  os: "darwin" | "linux" | "mingw32"
}

const targets: Target[] = [
  { name: "x86_64-linux", zig: "x86_64-linux-gnu.2.17", arch: "x86_64", os: "linux" },
  { name: "aarch64-linux", zig: "aarch64-linux-gnu.2.17", arch: "aarch64", os: "linux" },
  { name: "x86_64-linux-musl", zig: "x86_64-linux-musl", arch: "x86_64", os: "linux" },
  { name: "aarch64-linux-musl", zig: "aarch64-linux-musl", arch: "aarch64", os: "linux" },
  { name: "x86_64-macos", zig: "x86_64-macos", arch: "x86_64", os: "darwin" },
  { name: "aarch64-macos", zig: "aarch64-macos", arch: "aarch64", os: "darwin" },
  { name: "x86_64-windows", zig: "x86_64-windows-gnu", arch: "x86_64", os: "mingw32" },
  { name: "aarch64-windows", zig: "aarch64-windows-gnu", arch: "aarch64", os: "mingw32" },
]

function run(command: string, args: string[], cwd = root): string {
  const result = spawnSync(command, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] })
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed`)
  return result.stdout.trim()
}

function digest(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex")
}

async function download(url: string, path: string, sha256: string, name: string): Promise<void> {
  if (!existsSync(path) || digest(path) !== sha256) {
    const response = await fetch(url)
    if (!response.ok) throw new Error(`Failed to download ${name}: HTTP ${response.status}`)
    writeFileSync(path, new Uint8Array(await response.arrayBuffer()))
  }
  if (digest(path) !== sha256) throw new Error(`${name} archive SHA-256 mismatch`)
}

async function prepareSource(): Promise<void> {
  mkdirSync(dirname(archive), { recursive: true })
  mkdirSync(dirname(source), { recursive: true })
  await download(URL, archive, SHA256, "FFmpeg")
  if (!existsSync(source)) run("tar", ["-xf", archive, "-C", dirname(source)])
  await download(ZLIB_URL, zlibArchive, ZLIB_SHA256, "zlib")
  if (!existsSync(zlibSource)) run("tar", ["-xf", zlibArchive, "-C", dirname(zlibSource)])
}

function buildZlib(target: Target, cc: string, prefix: string): void {
  const build = join(cache, "build", target.name, "zlib")
  mkdirSync(build, { recursive: true })
  mkdirSync(join(prefix, "include"), { recursive: true })
  mkdirSync(join(prefix, "lib"), { recursive: true })
  const sources = ["adler32", "compress", "crc32", "deflate", "infback", "inffast", "inflate", "inftrees", "trees"]
  const objects = [...sources, "uncompr", "zutil"].map((file) => {
    const object = join(build, `${file}.o`)
    run(cc, [
      "-O3",
      "-fvisibility=hidden",
      ...(target.os === "mingw32" ? [] : ["-fPIC"]),
      `-I${zlibSource}`,
      "-c",
      join(zlibSource, `${file}.c`),
      "-o",
      object,
    ])
    return object
  })
  run("zig", ["ar", "rcs", join(prefix, "lib", "libz.a"), ...objects])
  for (const header of ["zlib.h", "zconf.h"]) {
    writeFileSync(join(prefix, "include", header), readFileSync(join(zlibSource, header)))
  }
}

// The library target and the test target: Linux tests link musl executables (see build.zig).
function hostTargets(): Target[] {
  const platform = { darwin: "macos", win32: "windows", linux: "linux" }[process.platform as string]
  const arch = { arm64: "aarch64", x64: "x86_64" }[process.arch as string]
  if (!platform || !arch) throw new Error(`Unsupported FFmpeg build host: ${process.platform}-${process.arch}`)
  const names = platform === "linux" ? [`${arch}-linux`, `${arch}-linux-musl`] : [`${arch}-${platform}`]
  return names.map((name) => targets.find((target) => target.name === name)!)
}

function prefixOf(target: Target): string {
  return join(cache, "prefix", target.name)
}

function isBuilt(target: Target): boolean {
  const marker = join(prefixOf(target), "opentui-build")
  return (
    existsSync(join(prefixOf(target), "lib", "libavcodec.a")) &&
    existsSync(marker) &&
    readFileSync(marker, "utf8") === BUILD_REVISION
  )
}

function buildTarget(target: Target): void {
  if (isBuilt(target)) return
  console.log(`Building FFmpeg ${VERSION} for ${target.name}...`)
  const prefix = prefixOf(target)
  rmSync(prefix, { recursive: true, force: true })
  const build = join(cache, "build", target.name)
  const tools = join(cache, "toolchains", target.name)
  rmSync(build, { recursive: true, force: true })
  mkdirSync(build, { recursive: true })
  mkdirSync(tools, { recursive: true })

  const sdk = target.os === "darwin" ? run("xcrun", ["--sdk", "macosx", "--show-sdk-path"]) : ""
  const cc = join(tools, "cc")
  writeFileSync(
    cc,
    target.os === "darwin"
      ? `#!/bin/sh\nexec xcrun --sdk macosx clang -arch ${target.arch === "aarch64" ? "arm64" : "x86_64"} -isysroot "${sdk}" -mmacosx-version-min=${MACOS_VERSION_MIN} "$@"\n`
      : target.os === "mingw32"
        ? `#!/bin/bash\nargs=()\nfor arg in "$@"; do\n  if [[ "$arg" == "-Wl,--pic-executable,-e,mainCRTStartup" ]]; then arg="-Wl,-e,mainCRTStartup"; fi\n  args+=("$arg")\ndone\nexec zig cc -target ${target.zig} "\${args[@]}"\n`
        : `#!/bin/sh\nexec zig cc -target ${target.zig} "$@"\n`,
  )
  chmodSync(cc, 0o755)
  buildZlib(target, cc, prefix)

  const configure = [
    `--prefix=${prefix}`,
    "--disable-everything",
    "--disable-autodetect",
    "--disable-programs",
    "--disable-doc",
    "--disable-debug",
    "--disable-network",
    "--disable-avdevice",
    "--disable-avfilter",
    "--disable-encoders",
    "--disable-muxers",
    "--disable-indevs",
    "--disable-outdevs",
    "--disable-hwaccels",
    "--disable-filters",
    "--disable-bzlib",
    "--disable-iconv",
    "--disable-lzma",
    "--enable-zlib",
    "--disable-gpl",
    "--disable-version3",
    "--disable-nonfree",
    "--enable-static",
    "--disable-shared",
    "--enable-small",
    "--enable-demuxer=mov",
    "--enable-decoder=h264,aac",
    "--enable-parser=h264,aac",
    "--enable-protocol=file",
    "--enable-swscale",
    "--enable-swresample",
    "--enable-cross-compile",
    `--cc=${cc}`,
    "--ar=zig ar",
    "--ranlib=zig ranlib",
    `--arch=${target.arch}`,
    `--target-os=${target.os}`,
    `--extra-cflags=-Os -ffunction-sections -fdata-sections -fvisibility=hidden -I${join(prefix, "include")}`,
    `--extra-ldflags=-L${join(prefix, "lib")}`,
    "--extra-libs=-lz",
    // VideoToolbox ships with macOS and needs no extra runtime dependencies.
    ...(target.os === "darwin" ? ["--enable-videotoolbox", "--enable-hwaccel=h264_videotoolbox"] : []),
    ...(target.arch === "x86_64" ? ["--disable-x86asm"] : []),
    ...(target.os === "mingw32" ? ["--disable-pic"] : ["--enable-pic"]),
    ...(target.os === "mingw32" ? ["--disable-pthreads", "--enable-w32threads"] : ["--enable-pthreads"]),
    ...(sdk ? [`--sysroot=${sdk}`] : []),
  ]
  run(join(source, "configure"), configure, build)
  if (target.os === "linux") {
    const configPath = join(build, "config.h")
    writeFileSync(
      configPath,
      readFileSync(configPath, "utf8").replace("#define HAVE_SYSCTL 1", "#define HAVE_SYSCTL 0"),
    )
  }
  run("make", [`-j${Math.max(1, availableParallelism())}`], build)
  run("make", ["install"], build)
  writeFileSync(join(prefix, "opentui-build"), BUILD_REVISION)
}

function selectTargets(): Target[] {
  if (process.argv.includes("--all")) return targets
  const requested = process.argv.find((argument) => argument.startsWith("--target="))?.slice("--target=".length)
  if (!requested) return hostTargets()
  const target = targets.find((candidate) => candidate.name === requested)
  if (!target) throw new Error(`Unknown FFmpeg target: ${requested}`)
  return [target]
}

const selectedTargets = selectTargets()
if (!selectedTargets.every(isBuilt)) await prepareSource()
for (const target of selectedTargets) buildTarget(target)
