#!/usr/bin/env python3
"""Build regions.json (the offline maps index) from pack folders.

Each folder under PACKS_DIR holds manifest.json plus the .pmtiles files the
manifest lists (built by ~/tools/topo-packs/build_pack.py). Sizes and sha256
are taken from the files themselves and must agree with the manifest, so a
truncated copy or a stale manifest fails here, not on a phone.

    make_regions_json.py PACKS_DIR [-o regions.json] [--stage UPLOAD_DIR]

--stage lays the files out the way the app fetches them, ready to upload to
the bucket root:

    UPLOAD_DIR/regions.json
    UPLOAD_DIR/<id>/<version>/<file>.pmtiles

Nothing is uploaded and nothing is sent anywhere.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def region_entry(folder: Path) -> dict:
    manifest = json.loads((folder / "manifest.json").read_text())
    pid = manifest["id"]
    if not ID_RE.match(pid):
        raise SystemExit(f"{folder}: bad pack id {pid!r}")
    if pid != folder.name:
        raise SystemExit(f"{folder}: manifest id {pid!r} != folder name")
    bbox = manifest["bbox"]
    if len(bbox) != 4 or bbox[0] >= bbox[2] or bbox[1] >= bbox[3]:
        raise SystemExit(f"{folder}: bad bbox {bbox}")
    files = []
    for layer, spec in sorted(manifest["files"].items()):
        name = spec["path"]
        if not NAME_RE.match(name) or name.startswith("."):
            raise SystemExit(f"{folder}: bad file name {name!r}")
        path = folder / name
        if not path.is_file():
            raise SystemExit(f"{folder}: {name} is missing")
        size = path.stat().st_size
        digest = sha256_of(path)
        if size != spec["bytes"] or digest != spec["sha256"]:
            raise SystemExit(
                f"{folder}: {name} does not match manifest.json "
                f"(size {size} vs {spec['bytes']}, sha256 differs: "
                f"{digest != spec['sha256']}). Rebuild the pack."
            )
        files.append({"name": name, "size": size, "sha256": digest})
    att = manifest.get("attribution", {})
    credits = [
        {k: c[k] for k in ("text", "license", "url") if k in c}
        for c in att.get("credits", [])
    ]
    return {
        "id": pid,
        "name": manifest["name"],
        "bbox": bbox,
        "version": str(manifest["version"]),
        "total_bytes": sum(f["size"] for f in files),
        "files": files,
        "attribution": {"map_text": att.get("map_text", ""), "credits": credits},
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("packs_dir", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=Path("regions.json"))
    ap.add_argument("--stage", type=Path, help="also copy files into upload layout")
    args = ap.parse_args()

    folders = sorted(
        p for p in args.packs_dir.iterdir() if (p / "manifest.json").is_file()
    )
    if not folders:
        print(f"no packs (manifest.json) under {args.packs_dir}", file=sys.stderr)
        return 1
    regions = [region_entry(f) for f in folders]
    index = {"schema": 1, "regions": regions}
    text = json.dumps(index, indent=2, sort_keys=True) + "\n"

    if args.stage:
        for r, folder in zip(regions, folders):
            dest = args.stage / r["id"] / r["version"]
            dest.mkdir(parents=True, exist_ok=True)
            for f in r["files"]:
                shutil.copy2(folder / f["name"], dest / f["name"])
        args.stage.mkdir(parents=True, exist_ok=True)
        (args.stage / "regions.json").write_text(text)

    args.out.write_text(text)
    for r in regions:
        print(f"{r['id']:12} {r['version']:10} {r['total_bytes'] / 1e6:8.1f} MB  {r['name']}")
    print(f"wrote {args.out}" + (f" and staged {args.stage}" if args.stage else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
