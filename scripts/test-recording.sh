#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v ffmpeg >/dev/null
fixtures=$(mktemp -d "${TMPDIR:-/tmp/}easyrecord-tests.XXXXXX")
trap 'rm -rf "$fixtures"' EXIT
for part in first second; do
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'color=c=gray:s=320x180:r=30:d=1' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=1' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=1' \
    -map 0:v -map 1:a -map 2:a -c:v libx264 -pix_fmt yuv420p -c:a aac "$fixtures/$part.mp4"
done
ffmpeg -hide_banner -loglevel error -y -i "$fixtures/first.mp4" -an -c:v copy "$fixtures/silent.mp4"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos15.0" \
  -module-cache-path "$fixtures/ModuleCache" Sources/RILEasyRecord/RecordingAssembler.swift \
  Tests/AssemblyCheck.swift -o "$fixtures/AssemblyCheck"
"$fixtures/AssemblyCheck" "$fixtures"
python3 - "$fixtures" <<'PY'
import sys, subprocess, struct, math
for name, starts in [('joined.mp4', [0.2, 1.2]), ('mixed-single.mp4', [0.2])]:
    raw = subprocess.check_output(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', sys.argv[1] + '/' + name, '-vn', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'])
    samples = struct.unpack('<%df' % (len(raw)//4), raw)
    for start in starts:
        values = samples[int(start*48000):int((start+0.5)*48000)]
        for frequency in [440, 880]:
            a = sum(v*math.cos(2*math.pi*frequency*i/48000) for i, v in enumerate(values))
            b = sum(v*math.sin(2*math.pi*frequency*i/48000) for i, v in enumerate(values))
            assert 2*math.hypot(a,b)/len(values) > 0.03, 'An audio source was lost'
print('PASS: both audio sources preserved with and without pause')
PY
