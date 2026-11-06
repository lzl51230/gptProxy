#!/usr/bin/env python3
"""Exercise the shipped C ABI against real SOCKS/TLS fixtures on macOS and Windows."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

class Buffer(ctypes.Structure):
    _fields_ = [('data', ctypes.c_void_p), ('length', ctypes.c_size_t)]

class Core:
    def __init__(self, library):
        self.lib = ctypes.CDLL(str(library))
        self.lib.cgp_core_create.restype = ctypes.c_void_p
        self.lib.cgp_core_call.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.cgp_core_call.restype = Buffer
        self.lib.cgp_core_buffer_free.argtypes = [Buffer]
        self.lib.cgp_core_destroy.argtypes = [ctypes.c_void_p]
        self.handle = self.lib.cgp_core_create()
    def call(self, **request):
        data = json.dumps(request).encode()
        buf = self.lib.cgp_core_call(self.handle, data, len(data))
        try:
            result = json.loads(ctypes.string_at(buf.data, buf.length))
        finally:
            self.lib.cgp_core_buffer_free(buf)
        if not result['ok']:
            raise RuntimeError(result['error'])
        return result.get('value')
    def close(self):
        self.call(op='heartbeatClose')
        self.lib.cgp_core_destroy(self.handle)

class Fixture:
    def __init__(self, root, mode='normal', status=401):
        self.root = root
        root.mkdir()
        config = root / 'openssl.cnf'
        config.write_text('''[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=probe.invalid
[ext]
subjectAltName=DNS:probe.invalid
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyCertSign,keyEncipherment
extendedKeyUsage=serverAuth
''')
        openssl = shutil.which('openssl')
        if not openssl:
            openssl = str(Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/usr/bin/openssl.exe')
        subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-config', str(config),
                        '-keyout', str(root/'key.pem'), '-out', str(root/'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        source = (Path(__file__).resolve().parent.parent/'Tests/ChatGPTProxyCoreTests/CodexConnectionTests.swift').read_text(encoding="utf-8")
        server = re.search(r'private static let server = #"""\n(.*?)\n"""#', source, re.S).group(1)
        self.process = subprocess.Popen([sys.executable, '-u', '-c', server, str(root), str(status), mode], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(400):
            try:
                self.port = int((root/'port').read_text(encoding='utf-8'))
                return
            except (FileNotFoundError, ValueError):
                pass
            time.sleep(.01)
        self.close()
        raise RuntimeError('SOCKS fixture failed to start')
    def rows(self):
        path = self.root/'events'
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []
    def wait(self, count):
        for _ in range(400):
            if len(self.rows()) >= count:
                return self.rows()
            time.sleep(.01)
        raise AssertionError(f'Expected {count} fixture events; got {self.rows()}')
    def close(self):
        self.process.terminate()
        self.process.wait(timeout=5)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library', type=Path, required=True)
    args = parser.parse_args()
    passed = []
    with tempfile.TemporaryDirectory(prefix='gptproxy-tls-') as temporary:
        def fixture(mode='normal', status=401):
            return Fixture(Path(temporary)/str(len(list(Path(temporary).iterdir()))), mode, status)
        def session(f):
            core = Core(args.library.resolve())
            core.call(op='heartbeatOpen', port=f.port, target='https://probe.invalid/test', caFile=str(f.root/'cert.pem'))
            return core
        f = fixture(); core = session(f)
        try:
            for instant in [0, 2, 10, 18, 26, 34, 42, 50, 58, 60]:
                result = core.call(op='heartbeat', nowSeconds=instant)
                assert result['isHealthy'], result
            assert result['connectionSeconds'] == 60
            core.close()
            rows = f.wait(12)
            assert sum(r.get('event') == 'connected' for r in rows) == 1
            assert sum(r.get('event') == 'closed' for r in rows) == 1
            for row in rows:
                request = row.get('request', '').lower()
                assert 'authorization:' not in request and 'cookie:' not in request
            passed.append('same physical connection, remote DNS, no credentials, release')
        finally: f.close()
        for mode,status in [('close',401),('large',401),('partial',401),('normal',302),('normal',403),('normal',503)]:
            f=fixture(mode,status); core=session(f)
            try:
                result=core.call(op='heartbeat',nowSeconds=0)
                assert not result['isHealthy'], (mode,status,result)
                core.close(); passed.append(f'rejected {mode}/{status}')
            finally: f.close()
        f=fixture('drop'); core=session(f)
        try:
            assert core.call(op='heartbeat',nowSeconds=0)['isHealthy']
            time.sleep(.05)
            assert not core.call(op='heartbeat',nowSeconds=2)['isHealthy']
            result=core.call(op='heartbeat',nowSeconds=3)
            assert result['isHealthy'] and result['connectionSeconds']==0
            core.close(); passed.append('no transparent reconnect; new observation resets age')
        finally: f.close()
        f=fixture('silent'); core=session(f); errors=[]
        def heartbeat():
            try: core.call(op='heartbeat',nowSeconds=0)
            except RuntimeError as error: errors.append(str(error))
        thread=threading.Thread(target=heartbeat)
        try:
            thread.start(); f.wait(2); start=time.monotonic()
            core.call(op='heartbeatCancel'); thread.join(timeout=2)
            assert not thread.is_alive() and errors==['cancelled'], errors
            assert time.monotonic()-start<2
            core.close(); passed.append('in-flight cancellation releases TLS socket')
        finally:
            thread.join(timeout=11); f.close()
        f=fixture('silent'); core=session(f); errors=[]
        thread=threading.Thread(target=heartbeat)
        try:
            thread.start(); f.wait(2); start=time.monotonic()
            core.call(op='heartbeatClose'); thread.join(timeout=2)
            assert not thread.is_alive() and errors==['cancelled'], errors
            assert time.monotonic()-start<2
            f.wait(3)
            core.close(); passed.append('concurrent close waits for physical socket release')
        finally:
            thread.join(timeout=11); f.close()
    print(json.dumps({'passed':len(passed),'cases':passed},indent=2))

if __name__ == '__main__': main()
