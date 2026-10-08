import json
from pathlib import Path


def canonical(entries: dict) -> str:
    lines = ["{", '  "version": 1,', '  "files": {']
    names = sorted(entries)
    for i, name in enumerate(names):
        e = entries[name]
        comma = "," if i < len(names) - 1 else ""
        lines.append(f'    "{name}": {{"etag": "{e["etag"]}", "last_modified": "{e["last_modified"]}", "size": {e["size"]}}}{comma}')
    lines += ["  }", "}"]
    return "\n".join(lines) + "\n"


def read(path: Path) -> dict:
    return json.loads(path.read_text())["files"]
