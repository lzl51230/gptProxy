#!/usr/bin/env python3
"""Refresh bundled notices from the pinned Cargo dependency graph."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root=Path(__file__).resolve().parent.parent
cargo=shutil.which('cargo') or str(Path.home()/'.cargo/bin/cargo')
metadata=json.loads(subprocess.check_output([cargo,'metadata','--format-version','1','--locked','--manifest-path',str(root/'core/Cargo.toml')],cwd=root))
path=root/'Resources/THIRD_PARTY_NOTICES.md'
text=path.read_text().split('\n## Rust core dependencies\n')[0]
text+='\n## Rust core dependencies\n\nThe native Rust core includes the following libraries. Their original license notices follow. Rust standard-library notices are included in the adjacent Rust-Std-Notices.html resource.\n'
for package in sorted(metadata['packages'],key=lambda package:package['name']):
    if package['source'] is None:
        continue
    directory=Path(package['manifest_path']).parent
    files=sorted(file for file in directory.iterdir() if file.is_file() and file.name.lower().startswith(('license','copying','copyright')))
    text+='\n### '+package['name']+' '+package['version']+'\n\nLicense: '+str(package.get('license'))+'\n'
    if package.get('repository'):
        text+='\n'+package['repository']+'\n'
    for file in files:
        text+='\n'+file.name+'\n\n```text\n'+file.read_text(errors='replace').strip()+'\n```\n'
# Readers copying the notice into a package see either the old file or the complete replacement.
temporary=path.with_suffix('.md.tmp')
temporary.write_text(text)
os.replace(temporary,path)
