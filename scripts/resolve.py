#!/usr/bin/env python3
"""Resolve the current stable Debian, Ubuntu LTS, and Alpine releases.

Prints a GitHub Actions matrix on stdout. Diagnostics go to stderr.
`resolve.py --shell DISTRO ARCH` prints shell assignments for one image.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import time
import urllib.error
import urllib.request

ARCHES = ("amd64", "arm64")
UNAME = {"amd64": "x86_64", "arm64": "aarch64"}
ALPINE_ARCH = {"amd64": "x86_64", "arm64": "aarch64"}
QEMU = {"amd64": "", "arm64": "qemu-aarch64"}
UA = "BoxRootfs (+https://github.com/BoxOSLab/BoxRootfs)"


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    last: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read().decode()
        except (urllib.error.URLError, TimeoutError) as exc:
            last = exc
            time.sleep(2 * (attempt + 1))
    raise SystemExit(f"failed to fetch {url}: {last}")


def parse_debian_release(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in text.splitlines():
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        data.setdefault(key.strip(), value.strip())
    for key in ("Codename", "Version", "Architectures"):
        if key not in data:
            raise SystemExit(f"debian Release is missing {key}")
    return data


def parse_ubuntu_lts(text: str) -> dict[str, str]:
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in text.splitlines() + [""]:
        if not line.strip():
            if current:
                records.append(current)
                current = {}
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current[key.strip()] = value.strip()
    supported = [
        rec for rec in records if rec.get("Supported") == "1" and rec.get("Dist") and rec.get("Version")
    ]
    if not supported:
        raise SystemExit("no supported Ubuntu LTS in meta-release-lts")
    # The file is chronological. Later entries stay Supported because of ESM,
    # so the current LTS is the last one, not merely any supported one.
    rec = supported[-1]
    version = rec["Version"].removesuffix(" LTS").strip()
    return {"codename": rec["Dist"], "version": version, "name": rec.get("Name", "")}


def parse_alpine_minirootfs(text: str) -> dict[str, str]:
    items: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for raw in text.splitlines():
        if raw == "-" or raw.startswith("- "):
            if current:
                items.append(current)
            current = {}
            rest = raw[1:].strip()
            if ":" in rest:
                key, value = rest.split(":", 1)
                value = value.strip().strip("\"'")
                if value not in {"|", ">", "|-", ">-"}:
                    current[key.strip()] = value
            continue
        if current is None or not raw.startswith("  ") or raw.startswith("   "):
            continue
        body = raw.strip()
        if ":" not in body:
            continue
        key, value = body.split(":", 1)
        value = value.strip().strip("\"'")
        if value in {"|", ">", "|-", ">-"}:
            continue
        current[key.strip()] = value
    if current:
        items.append(current)
    for item in items:
        if item.get("flavor") == "alpine-minirootfs":
            for key in ("version", "file", "sha256", "branch", "arch"):
                if not item.get(key):
                    raise SystemExit(f"alpine minirootfs entry missing {key}")
            return item
    raise SystemExit("alpine-minirootfs entry not found")


def filename(distro: str, version: str, codename: str, distro_arch: str) -> str:
    if distro == "alpine":
        return f"alpine-{version}-{distro_arch}.tar.xz"
    return f"{distro}-{version}-{codename}-{distro_arch}.tar.xz"


def image_row(distro: str, arch: str, *, version: str, codename: str, channel: str,
              distro_arch: str, upstream_url: str = "", upstream_sha256: str = "") -> dict[str, str]:
    return {
        "distro": distro,
        "arch": arch,
        "distro_arch": distro_arch,
        "uname": UNAME[arch],
        "qemu": QEMU[arch],
        "version": version,
        "codename": codename,
        "channel": channel,
        "filename": filename(distro, version, codename, distro_arch),
        "upstream_url": upstream_url,
        "upstream_sha256": upstream_sha256,
    }


def debian_images(arches: list[str]) -> list[dict[str, str]]:
    release = parse_debian_release(fetch("https://deb.debian.org/debian/dists/stable/Release"))
    have = set(release["Architectures"].split())
    rows = []
    for arch in arches:
        if arch not in have:
            raise SystemExit(f"debian stable does not publish {arch}")
        rows.append(image_row(
            "debian", arch,
            version=release["Version"],
            codename=release["Codename"],
            channel="stable",
            distro_arch=arch,
        ))
    return rows


def ubuntu_images(arches: list[str]) -> list[dict[str, str]]:
    meta = parse_ubuntu_lts(fetch("https://changelogs.ubuntu.com/meta-release-lts"))
    release = parse_debian_release(
        fetch(f"https://archive.ubuntu.com/ubuntu/dists/{meta['codename']}/Release")
    )
    have = set(release["Architectures"].split())
    rows = []
    for arch in arches:
        if arch not in have:
            raise SystemExit(f"ubuntu {meta['codename']} does not publish {arch}")
        rows.append(image_row(
            "ubuntu", arch,
            version=meta["version"],
            codename=meta["codename"],
            channel="lts",
            distro_arch=arch,
        ))
    return rows


def alpine_images(arches: list[str]) -> list[dict[str, str]]:
    found: dict[str, dict[str, str]] = {}
    for arch in arches:
        alpine_arch = ALPINE_ARCH[arch]
        url = f"https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/{alpine_arch}/latest-releases.yaml"
        found[arch] = parse_alpine_minirootfs(fetch(url))
    versions = {item["version"] for item in found.values()}
    if len(versions) != 1:
        raise SystemExit(f"alpine arches disagree on latest-stable: {versions}")
    rows = []
    for arch, item in found.items():
        alpine_arch = item["arch"]
        upstream = (
            f"https://dl-cdn.alpinelinux.org/alpine/{item['branch']}/releases/"
            f"{alpine_arch}/{item['file']}"
        )
        rows.append(image_row(
            "alpine", arch,
            version=item["version"],
            codename=item["branch"],
            channel="stable",
            distro_arch=alpine_arch,
            upstream_url=upstream,
            upstream_sha256=item["sha256"],
        ))
    return rows


def selected(name: str, env_key: str, allowed: tuple[str, ...]) -> list[str]:
    raw = os.environ.get(env_key, "all").strip() or "all"
    if raw == "all":
        return list(allowed)
    if raw not in allowed:
        raise SystemExit(f"{name} must be one of: all, {', '.join(allowed)}")
    return [raw]


def build_matrix() -> dict[str, list[dict[str, str]]]:
    distros = selected("DISTRO", "DISTRO", ("debian", "ubuntu", "alpine"))
    arches = selected("ARCH", "ARCH", ARCHES)
    rows: list[dict[str, str]] = []
    if "debian" in distros:
        rows.extend(debian_images(arches))
    if "ubuntu" in distros:
        rows.extend(ubuntu_images(arches))
    if "alpine" in distros:
        rows.extend(alpine_images(arches))
    if not rows:
        raise SystemExit("empty build matrix")
    return {"include": rows}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shell", nargs=2, metavar=("DISTRO", "ARCH"))
    args = parser.parse_args()
    if args.shell:
        os.environ["DISTRO"], os.environ["ARCH"] = args.shell
    matrix = build_matrix()
    if args.shell:
        rows = matrix["include"]
        if len(rows) != 1:
            raise SystemExit(f"expected one image, got {len(rows)}")
        for key, value in rows[0].items():
            print(f"{key.upper()}={shlex.quote(value)}")
        return
    json.dump(matrix, sys.stdout, indent=2)
    sys.stdout.write("\n")
    for row in matrix["include"]:
        print(
            f"{row['distro']} {row['version']} {row['codename']} {row['distro_arch']}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
