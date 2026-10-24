#!/usr/bin/env python3
"""Turn per-image metadata into a release manifest, checksum list, and notes."""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

BOXKERNEL = "https://github.com/BoxOSLab/BoxKernel"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) != 6:
        raise SystemExit(
            "usage: publish.py IMAGES_DIR TAG REPO latest.json notes.md"
        )
    src = Path(sys.argv[1])
    tag = sys.argv[2]
    repo = sys.argv[3]
    latest_path = Path(sys.argv[4])
    notes_path = Path(sys.argv[5])

    metas = sorted(src.glob("*.meta.json"))
    if not metas:
        raise SystemExit(f"no image metadata in {src}")

    images = []
    sums = []
    for meta_path in metas:
        meta = json.loads(meta_path.read_text())
        filename = meta["filename"]
        tar = src / filename
        if not tar.is_file():
            raise SystemExit(f"missing tarball {tar}")
        digest = sha256(tar)
        if digest != meta["sha256"]:
            raise SystemExit(f"checksum mismatch for {filename}")
        size = tar.stat().st_size
        if size != meta["size"]:
            raise SystemExit(f"size mismatch for {filename}")
        qemu = meta.get("qemu") or None
        image = {
            "distro": meta["distro"],
            "channel": meta["channel"],
            "version": meta["version"],
            "codename": meta["codename"],
            "arch": meta["arch"],
            "distro_arch": meta["distro_arch"],
            "uname": meta["uname"],
            "qemu": qemu,
            "filename": filename,
            "sha256": digest,
            "size": size,
            "url": f"https://github.com/{repo}/releases/download/{tag}/{filename}",
        }
        if meta.get("upstream_sha256"):
            image["upstream_sha256"] = meta["upstream_sha256"]
            image["upstream_url"] = meta["upstream_url"]
        images.append(image)
        sums.append(f"{digest}  {filename}")

    names = [img["filename"] for img in images]
    if len(names) != len(set(names)):
        raise SystemExit(f"duplicate filenames: {names}")
    images.sort(key=lambda img: (img["distro"], img["arch"]))

    document = {
        "schema": 1,
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "release": tag,
        "repository": f"https://github.com/{repo}",
        "boxkernel": BOXKERNEL,
        "images": images,
    }
    payload = json.dumps(document, indent=2) + "\n"
    (src / "manifest.json").write_text(payload)
    latest_path.write_text(payload)
    (src / "SHA256SUMS").write_text("\n".join(sums) + "\n")

    lines = [
        f"Stable rootfs images for [BoxKernel]({BOXKERNEL}).",
        "",
        "Extract as a normal user. These archives contain no device nodes.",
        "",
        "| Distro | Version | Arch | Bytes | SHA256 |",
        "|---|---|---|---:|---|",
    ]
    for img in images:
        short = img["sha256"][:12]
        lines.append(
            f"| {img['distro']} | {img['version']} ({img['codename']}) | {img['distro_arch']} | {img['size']} | `{short}…` |"
        )
    lines += [
        "",
        "```console",
        "tar -C rootfs -xJf <file>.tar.xz",
        "proot -r rootfs /bin/sh",
        "proot -0 -r rootfs /bin/sh",
        "```",
        "",
        "For a foreign architecture, add `-q` with the `qemu` value from `manifest.json`.",
        "",
        "`latest.json` on the main branch points at this release.",
        "",
    ]
    notes_path.write_text("\n".join(lines))
    print(f"published {len(images)} images as {tag}", file=sys.stderr)


if __name__ == "__main__":
    main()
