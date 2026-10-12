# Video fixtures

`testsrc-160x90-24fps-2s.mp4` is a deterministic two-second 160x90 24 fps H.264 video with a 48 kHz stereo AAC
440 Hz sine track. It contains only generated content.

Generated with ffmpeg 6.1:

```sh
ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=24:duration=2" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" -ac 2 \
  -c:v libx264 -preset veryslow -crf 30 -pix_fmt yuv420p -g 24 -bf 0 \
  -c:a aac -b:a 64k -map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
  -movflags +faststart testsrc-160x90-24fps-2s.mp4
```
