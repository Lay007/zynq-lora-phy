"""Build board measurement tools and record compiler, source and binary hashes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build(cc: str, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    flags = ['-O2', '-static', '-Wall', '-Wextra', '-Werror']
    info = {'compiler': cc, 'compiler_version': subprocess.check_output([cc, '--version'], text=True),
            'target': subprocess.check_output([cc, '-dumpmachine'], text=True).strip(),
            'flags': flags, 'libraries': ['-lm'], 'files': {}}
    for name in ('lora_trace_stream', 'lora_tx_noise'):
        source = ROOT / 'board/per' / (name + '.c')
        binary = output / name
        subprocess.run([cc, *flags, '-o', str(binary), str(source), '-lm'], check=True)
        info['files'][name] = {'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                              'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    (output / 'per-tools-manifest.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')
    return info


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cc', default=os.environ.get('CC', 'arm-linux-gnueabihf-gcc'))
    parser.add_argument('--out', type=Path, default=ROOT / 'board/per')
    args = parser.parse_args()
    print(json.dumps(build(args.cc, args.out), indent=2))
