#!/usr/bin/env python3
"""Exercise the real CLI controller with isolated children; never change routing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile

FIXTURE = '''#!/usr/bin/python3
import os, pathlib, sys, time
root = pathlib.Path(__file__).parent
sys.stdin.buffer.read()
os.write(1, b'ProxyBridge CLI 4.1.1\\nProfile "ChatGPT Only": 1 proxies, 3 rules applied\\nDNS proxy: off (host name rules and send hostname do not work)\\nRedirecting traffic. Press Ctrl+C to stop.\\n')
while not (root / 'go').exists(): time.sleep(.005)
line = b'x' * 4095 + b'\\n'
for i in range(16384):
    data = memoryview(line)
    while data:
        data = data[os.write(1 if i % 2 == 0 else 2, data):]
os.close(2)
# stdout follows stderr EOF, allowing the reader to drain both before this marker.
time.sleep(.1)
os.write(1, ('DRAINED_' + (root / 'round').read_text() + '\\n').encode())
(root / 'done').touch()
while True: time.sleep(.1)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=1800)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error('--seconds must be positive')
    root = Path(__file__).resolve().parent.parent
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
    subprocess.run(['swift', 'build'], cwd=root, env=env, check=True)
    build = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, env=env, text=True).strip())
    objects = [p for p in (build / 'ChatGPTProxyApp.product/Objects.LinkFileList').read_text().splitlines()
               if '/ChatGPTProxyApp.build/' not in p]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = output / 'fake-cli'
    fixture.write_text(FIXTURE)
    fixture.chmod(0o700)
    (output / 'samples.jsonl').touch()
    sources = [root / 'Package.swift', *sorted((root / 'Sources/ChatGPTProxyCore').glob('*.swift'))]
    (output / 'source-hashes.json').write_text(json.dumps(
        {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, indent=2))
    with tempfile.TemporaryDirectory(prefix='gptproxy-memory-build-') as temporary:
        executable = Path(temporary) / 'probe'
        command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                   '-I', str(build / 'Modules'), '-Xcc', '-fmodule-map-file=' + str(build / 'CCodexTransport.build/module.modulemap'),
                   '-Xcc', '-I' + str(root / 'Sources/CCodexTransport/include'),
                   '-Xcc', '-fmodule-map-file=' + str(root / '.build/checkouts/Yams/Sources/CYaml/include/module.modulemap'),
                   '-lcurl', str(root / 'scripts/CLIMemoryProbe.swift'), *objects, '-o', str(executable)]
        subprocess.run(command, cwd=root, env=env, check=True)
        process = subprocess.Popen([str(executable), str(output), str(root / 'Resources/ChatGPT-Only.pbprofile'), str(args.seconds)],
                                   env=env, start_new_session=True)
        try:
            result = process.wait(timeout=args.seconds + 60)
            if result:
                raise subprocess.CalledProcessError(result, process.args)
        finally:
            # Also clean up a fixture if the probe fails or is interrupted.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            process.wait(timeout=10)
    print(output / 'summary.json')


if __name__ == '__main__':
    main()
