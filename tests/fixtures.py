"""Fetch immutable upstream test inputs and verify their SHA-256 checksums."""

import hashlib
import json
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / "timendus.json").read_text())
CACHE = HERE / ".cache" / "timendus"


def fixture(path):
    expected = MANIFEST["files"][path]
    target = CACHE / path
    if target.exists():
        data = target.read_bytes()
    else:
        url = (f"https://raw.githubusercontent.com/{MANIFEST['repository']}/"
               f"{MANIFEST['commit']}/{quote(path)}")
        with urlopen(url, timeout=30) as response:
            data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValueError(f"Unexpectedly large fixture: {path}")
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"Fixture checksum mismatch: {target}; remove it and retry")
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return target
