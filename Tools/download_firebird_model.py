#!/usr/bin/env python3
"""Fetch hash-pinned model files for local development tests, never note content.
The iOS app uses its encrypted streaming installer instead of this developer cache.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

# Pinned checkpoints: lock file and default development cache.
MODELS = {
    'qwen3-vl': ('QwenVLModel.lock.json', 'work/QwenVLModel'),
    'paddleocr-vl': ('PaddleOCRVLModel.lock.json', 'work/PaddleOCRVLModel'),
    'glm-ocr': ('FirebirdModel.lock.json', 'work/FirebirdModel'),
}
parser = argparse.ArgumentParser()
parser.add_argument('--model', choices=MODELS, default='glm-ocr')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
lock_name, default_output = MODELS[args.model]
args.output = args.output or Path(default_output)
lock = json.loads((Path(__file__).resolve().parents[1] / 'VisionNotes/Resources' / lock_name).read_text())
args.output.mkdir(parents=True, exist_ok=True)

def verify(path, asset):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return path.stat().st_size == asset['bytes'] and digest.hexdigest() == asset['sha256']

for asset in lock['assets']:
    name = asset['name']
    if Path(name).name != name or '..' in name:
        raise ValueError('Unsafe asset name')
    path = args.output / name
    if path.exists() and verify(path, asset):
        print('Verified cached', name, flush=True)
        continue
    temporary = path.with_suffix(path.suffix + '.partial')
    url = f"https://huggingface.co/{lock['model']}/resolve/{lock['revision']}/{name}"
    print('Downloading', name, asset['bytes'], 'bytes', flush=True)
    try:
        with urllib.request.urlopen(url, timeout=90) as response, temporary.open('wb') as stream:
            count = 0
            for chunk in iter(lambda: response.read(4 * 1024 * 1024), b''):
                count += len(chunk)
                if count > asset['bytes']:
                    raise ValueError('Asset exceeds pinned size')
                stream.write(chunk)
        if not verify(temporary, asset):
            raise ValueError('Asset failed SHA-256/size verification')
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
print('All model assets verified at', lock['revision'], flush=True)
