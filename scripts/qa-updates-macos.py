#!/usr/bin/env python3
"""Run the opt-in Debug desktop update harness against isolated signed bundles.

Build ChatGPTProxyApp Debug for arm64 and x86_64 first, and scripts/build.sh
for the release resources. Authorization/cancel cases require native macOS UI.
The running case requires ChatGPT to be open; it never launches or quits it.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("case", choices=["stopped", "running", "authorization", "cancel"])
parser.add_argument("--helper", choices=["built", "original"], default="built",
                    help="Use the saved original helper in the new bundle to restore it after acceptance")
args = parser.parse_args()
qa = ROOT / "dist/qa/macos-updates" / (args.case + "-" + uuid.uuid4().hex[:8])
qa.mkdir(parents=True)

def run(*command):
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

def bundle(destination, version):
    shutil.copytree(ROOT / "build/ChatGPT Proxy.app", destination)
    if args.case == "running":
        helper = Path("/Library/PrivilegedHelperTools/local.alex.chatgpt-proxy.dns") if version == "2.3.9" else (
            ROOT / "dist/qa/macos-updates/original-DNSProtectionHelper" if args.helper == "original" else
            ROOT / "build/ChatGPT Proxy.app/Contents/Resources/DNSProtectionHelper")
        shutil.copy2(helper, destination / "Contents/Resources/DNSProtectionHelper")
    executable = destination / "Contents/MacOS/ChatGPTProxyLauncher"
    run("/usr/bin/lipo", "-create",
        str(ROOT / ".build/arm64-apple-macosx/debug/ChatGPTProxyApp"),
        str(ROOT / ".build/x86_64-apple-macosx/debug/ChatGPTProxyApp"), "-output", str(executable))
    info = destination / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["CFBundleShortVersionString"] = version
    info.write_bytes(plistlib.dumps(metadata))
    manifest = destination / "Contents/Resources/update-manifest.json"
    manifest.write_text(json.dumps({"format": 1, "version": version, "platform": "macos-universal",
                                   "files": sorted(str(p.relative_to(destination)) for p in destination.rglob("*")
                                                   if p.is_file() and "_CodeSignature" not in p.parts and p != manifest)}))
    run("/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(destination))

parent = qa / "installed"
parent.mkdir()
target = parent / "ChatGPT Proxy.app"
bundle(target, "2.3.9")
new = qa / "fixture/ChatGPT Proxy.app"
bundle(new, "2.4.0")
archive = qa / "new.zip"
run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(new), str(archive))
name = "ChatGPT-Proxy-2.4.0-Universal.zip"
(qa / "release.json").write_text(json.dumps({
    "tag_name": "v2.4.0", "draft": False, "prerelease": False,
    "assets": [{"name": name, "size": archive.stat().st_size,
                "digest": "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest(),
                "browser_download_url": "https://github.com/lzl51230/gptProxy/releases/download/v2.4.0/" + name}]}))
if args.case in ("authorization", "cancel"):
    parent.chmod(0o555)
environment = dict(os.environ, GPTPROXY_UPDATE_QA=str(qa), GPTPROXY_UPDATE_QA_CASE=args.case)
print("QA output:", qa, flush=True)
with (qa / "desktop.log").open("w") as log:
    process = subprocess.Popen([str(target / "Contents/MacOS/ChatGPTProxyLauncher")], env=environment,
                               stdout=log, stderr=log)
    deadline = time.monotonic() + 480
    try:
        while not (qa / "result.json").exists():
            # Reap the old launcher immediately so kill(pid, 0) in the worker
            # observes its exit rather than a zombie owned by this harness.
            process.poll()
            if time.monotonic() > deadline:
                raise TimeoutError("Desktop acceptance did not finish; retain evidence and quit the test app normally")
            time.sleep(0.5)
        result = json.loads((qa / "result.json").read_text())
        print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
        # The harness exits normally after writing evidence, including the restarted PID.
        time.sleep(8)
        process.wait(timeout=15)
        if not result["success"]:
            raise RuntimeError("Desktop update QA failed")
    finally:
        parent.chmod(0o755)
