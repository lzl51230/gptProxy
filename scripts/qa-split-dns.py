#!/usr/bin/env python3
"""Native resolver acceptance with unique .test domains and two observable upstreams.

Windows: run in an elevated test shell. Uses isolated loopback addresses and .test domains.
macOS: invoked by DomainResolverTests when GPTPROXY_SYSTEM_DNS_QA=1 is set.
"""
import argparse
import base64
import ctypes
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]


class Resolver:
    def __init__(self, address, port, ipv4, ipv6=None):
        self.addresses = {1: ipv4, 28: ipv6}
        self.seen = []
        self.socket = socket.socket(type=socket.SOCK_DGRAM)
        self.socket.bind((address, port))
        self.socket.settimeout(0.2)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                packet, peer = self.socket.recvfrom(4096)
            except socket.timeout:
                continue
            end = packet.index(b'\0', 12)
            pos, labels = 12, []
            while pos < end:
                size = packet[pos]
                labels.append(packet[pos + 1:pos + size + 1].decode('ascii').lower())
                pos += size + 1
            kind = struct.unpack_from('!H', packet, end + 1)[0]
            self.seen.append(('.'.join(labels), kind))
            value = self.addresses.get(kind)
            answer = b''
            if value:
                ip = ipaddress.ip_address(value).packed
                answer = struct.pack('!HHHIH', 0xc00c, kind, 1, 0, len(ip)) + ip
            header = packet[:2] + struct.pack('!5H', 0x8180, 1, int(bool(answer)), 0, 0)
            self.socket.sendto(header + packet[12:end + 5] + answer, peer)

    def close(self):
        self.stop.set()
        self.thread.join()
        self.socket.close()


def native_query(name, expected, resolver, other):
    family, kind = (socket.AF_INET6, 28) if ':' in expected else (socket.AF_INET, 1)
    records = socket.getaddrinfo(name + '.', None, family, socket.SOCK_STREAM)
    assert {row[4][0] for row in records} == {expected}, (name, records)
    question = (name.lower(), kind)
    assert question in resolver.seen and question not in other.seen, question


def windows_policy(operation, transaction, domains, ordinary=False):
    encoded = base64.b64encode(json.dumps(domains).encode()).decode()
    script = "$ErrorActionPreference='Stop';"
    endpoint = '127.0.0.2' if ordinary else '127.0.0.3'
    adapter = (ROOT / 'windows/ChatGPTProxy.Service/DomainDns.ps1').read_text(encoding='utf-8')
    script += "& { " + adapter + f" }} -operation '{operation}' -transaction '{transaction}' -domainData '{encoded}' -loopback '{endpoint}'"
    command = base64.b64encode(script.encode('utf-16le')).decode()
    result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', command],
                            capture_output=True, timeout=25)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace')[:1500])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mac-suffix')
    args = parser.parse_args()
    windows = os.name == 'nt'
    if windows and not ctypes.windll.shell32.IsUserAnAdmin():
        parser.error('Windows requires an elevated test shell')
    if not windows and not args.mac_suffix:
        parser.error('Use DomainResolverTests on macOS')
    suffix = args.mac_suffix or f'{uuid.uuid4().hex}.test'
    protected = [f'chatgpt.com.{suffix}', f'challenges.cloudflare.com.{suffix}']
    ordinary = [f'www.cloudflare.com.{suffix}', f'example.org.{suffix}', f'cn.{suffix}', f'internal.{suffix}']
    upstream = Resolver('127.0.0.3' if windows else '127.0.0.1', 53 if windows else 17853, '192.0.2.11')
    baseline = None
    resources = []
    try:
        baseline = Resolver('127.0.0.2' if windows else '127.0.0.1', 53 if windows else 17854,
                            '192.0.2.22', '2001:db8::22')
        if windows:
            for domains, is_ordinary in [(ordinary, True), (protected, False)]:
                txn = uuid.uuid4()
                resources.append((txn, domains, is_ordinary))
                windows_policy('domainDNSApply', txn, domains, is_ordinary)
                windows_policy('verify', txn, domains, is_ordinary)
        for name in [protected[0], 'API.' + protected[0], protected[1]]:
            native_query(name, '192.0.2.11', upstream, baseline)
        for name in [ordinary[0], 'chatgpt.com.' + ordinary[1], 'www.' + ordinary[2], 'files.' + ordinary[3]]:
            native_query(name, '192.0.2.22', baseline, upstream)
        upstream.addresses[1] = '192.0.2.33'
        native_query('fresh.' + protected[0], '192.0.2.33', upstream, baseline)
        upstream.close()
        native_query('offline.' + ordinary[2], '192.0.2.22', baseline, upstream)
        native_query('ipv6.' + ordinary[3], '2001:db8::22', baseline, upstream)
        print('Native A/AAAA responses and both upstream query logs verified')
    finally:
        errors = []
        for txn, domains, is_ordinary in reversed(resources):
            try:
                windows_policy('domainDNSRestore', txn, domains, is_ordinary)
            except Exception as error:
                errors.append(f'{txn}: {error}')
        if baseline:
            baseline.close()
        if not upstream.stop.is_set():
            upstream.close()
        if errors:
            raise RuntimeError('Could not restore test policies: ' + ', '.join(errors))


if __name__ == '__main__':
    main()
