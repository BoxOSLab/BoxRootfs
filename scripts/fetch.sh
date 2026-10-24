#!/usr/bin/env bash
# Download one published rootfs and extract it.
# Usage: fetch.sh DISTRO ARCH
# DISTRO is debian, ubuntu, or alpine. ARCH is amd64 or arm64
# (x86_64 and aarch64 are accepted too).
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 DISTRO ARCH" >&2
  exit 2
fi

distro=$1
arch=$2
case "$arch" in
  amd64 | x86_64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)
    echo "arch must be amd64 or arm64" >&2
    exit 2
    ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${BOXROOTFS_MANIFEST:-https://raw.githubusercontent.com/BoxOSLab/BoxRootfs/main/latest.json}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ $manifest == http://* || $manifest == https://* ]]; then
  if ! curl -fsSL --retry 5 --retry-delay 2 "$manifest" -o "$work/latest.json"; then
    echo "could not download $manifest" >&2
    echo "the first rootfs release may still be running" >&2
    exit 1
  fi
else
  cp "$manifest" "$work/latest.json"
fi

python3 - "$work/latest.json" "$distro" "$arch" "$work/image.env" <<'PY'
import json, shlex, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
distro, arch, dest = sys.argv[2], sys.argv[3], sys.argv[4]
images = doc.get("images") or []
match = [img for img in images if img["distro"] == distro and img["arch"] == arch]
if not match:
    available = ", ".join(f"{img['distro']}/{img['arch']}" for img in images) or "none"
    raise SystemExit(f"no {distro} {arch} image in this manifest (have: {available})")
img = match[0]
fields = {
    "url": img["url"],
    "sha": img["sha256"],
    "filename": img["filename"],
    "qemu": img.get("qemu") or "",
    "version": img["version"],
    "codename": img["codename"],
    "distro_arch": img["distro_arch"],
}
with open(dest, "w", encoding="utf-8") as handle:
    for key, value in fields.items():
        handle.write(f"{key}={shlex.quote(value)}\n")
PY

# shellcheck disable=SC1091
source "$work/image.env"

mkdir -p "$root/images"
tarball="$root/images/$filename"
if [[ ! -f $tarball ]] || ! echo "$sha  $tarball" | sha256sum -c - >/dev/null 2>&1; then
  echo "downloading $filename"
  curl -fL --retry 5 --retry-delay 2 -o "$tarball.partial" "$url"
  mv "$tarball.partial" "$tarball"
fi
echo "$sha  $tarball" | sha256sum -c -

dest="$root/rootfs/${distro}-${arch}"
if [[ -d $dest && -n $(ls -A "$dest" 2>/dev/null || true) ]]; then
  echo "$dest already exists; remove it to extract again" >&2
  exit 1
fi
mkdir -p "$dest"
tar -C "$dest" -xJf "$tarball"
echo "extracted $distro $version ($codename, $distro_arch) to $dest"
echo "proot -r $dest /bin/sh"
echo "proot -0 -r $dest /bin/sh"
if [[ -n $qemu ]]; then
  echo "proot -r $dest -q $qemu /bin/sh"
fi
