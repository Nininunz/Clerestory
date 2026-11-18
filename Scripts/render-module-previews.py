#!/usr/bin/env python3
"""Render isolated SwiftUI scenarios, optionally capturing the window compositor."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import time
import fcntl

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = pathlib.Path('/tmp/openyoink-preview-request.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module', action='append', default=[], help='Module slug; repeat for multiple modules')
    parser.add_argument('--scenario', action='append', default=[], help='Scenario ID or case-insensitive label substring; repeat to include several')
    parser.add_argument('--list', action='store_true', help='List matching scenarios without rendering')
    parser.add_argument('--capture', choices=['window', 'snapshot'], default='window', help='Window captures preserve blur/materials; snapshot runs offscreen')
    parser.add_argument('--output', type=pathlib.Path, help='Output folder (default: unique temporary folder)')
    parser.add_argument('--no-open', action='store_true')
    args = parser.parse_args()
    output = (args.output or pathlib.Path(tempfile.mkdtemp(prefix='openyoink-previews-', dir='/tmp'))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    with open('/tmp/openyoink-preview.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error('Another preview run is active')
        config = dict(output=str(output), modules=args.module, scenarios=args.scenario,
                      list=args.list, capture=args.capture)
        CONFIG.write_text(json.dumps(config))
        process = None
        handled = set()
        try:
            with (output / 'build.log').open('w') as log:
                process = subprocess.Popen(['xcodebuild', 'test', '-quiet', '-project', 'Open-Yoink.xcodeproj',
                    '-scheme', 'Clerestory', '-destination', 'platform=macOS', '-derivedDataPath', '/tmp/openyoink-derived',
                    '-only-testing:ClerestoryTests/IslandModulePreviewTests', 'CODE_SIGNING_ALLOWED=NO'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
                while process.poll() is None:
                    for request in output.glob('capture-*.json'):
                        if request in handled:
                            continue
                        handled.add(request)
                        data = json.loads(request.read_text())
                        for attempt in range(3):
                            capture = subprocess.run(['/usr/sbin/screencapture', '-x', '-o', '-l', str(data['window']), data['path']], capture_output=True, text=True)
                            if capture.returncode == 0:
                                break
                            time.sleep(.3)
                        response = request.with_suffix('.pending')
                        response.write_text('ok' if capture.returncode == 0 else capture.stderr or 'Capture failed')
                        response.replace(request.with_suffix('.done'))
                    time.sleep(.1)
            if process.returncode:
                raise SystemExit(f'Preview export failed. See {output / "build.log"}')
            manifest = json.loads((output / 'manifest.json').read_text())
            for entry in manifest:
                print(f"{entry['module']}/{entry['id']}: {entry['scenario']}")
            print(f'Output: {output}')
            samples = output / 'samples.json'
            if samples.exists():
                for module, path in json.loads(samples.read_text()).items():
                    print(f'Sample files ({module}): {path}')
            if not args.list and not args.no_open:
                subprocess.run(['open', str(output / 'index.html')], check=True)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait()
            CONFIG.unlink(missing_ok=True)
            for path in handled:
                path.unlink(missing_ok=True)
                path.with_suffix('.done').unlink(missing_ok=True)


if __name__ == '__main__':
    main()
