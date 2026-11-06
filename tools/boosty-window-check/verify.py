"""Check only media produced by the owned-window probe (ffmpeg required)."""
import json
import re
import subprocess
import sys
from pathlib import Path

for log_file in sys.argv[1:]:
    log = Path(log_file).read_text()
    assert 'LIVE_WINDOW_CHECK_PASSED:' in log, f'{log_file}: probe did not pass'
    media = re.search(r'VIDEO_PATH=(.*)', log).group(1)
    info = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-show_entries',
        'format=duration:stream=width,height,codec_name', '-of', 'json', media,
    ]))
    stream = info['streams'][0]
    assert stream['codec_name'] == 'h264'
    assert 120 <= stream['width'] <= 1920 and 80 <= stream['height'] <= 1080
    assert float(info['format']['duration']) > 0
    pixels = subprocess.check_output([
        'ffmpeg', '-v', 'error', '-i', media, '-vf',
        'crop=2:2:iw/2:ih/2,scale=1:1,format=rgb24', '-f', 'rawvideo', '-',
    ])
    # Closing/minimizing may fade to black, which is explicitly marked incomplete.
    # Red is the replacement content introduced after the title change.
    assert pixels and not any(pixels[i] > pixels[i + 2] + 100 for i in range(0, len(pixels), 3)), 'Replacement content recorded'
    print(Path(log_file).name, stream['width'], stream['height'], 'PASS; no replacement frames')
