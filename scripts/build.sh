#!/usr/bin/env bash
# Build one BoxKernel rootfs.
# Usage: build.sh [debian|ubuntu|alpine] [amd64|arm64]
# Version fields come from the environment, or from scripts/resolve.py.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)

if [[ ${1:-} != "" ]]; then
  DISTRO=$1
fi
if [[ ${2:-} != "" ]]; then
  ARCH=$2
fi

: "${DISTRO:?set DISTRO or pass it as the first argument}"
: "${ARCH:?set ARCH or pass it as the second argument}"

case "$DISTRO" in
  debian | ubuntu | alpine) ;;
  *)
    echo "unknown distro: $DISTRO" >&2
    exit 2
    ;;
esac
case "$ARCH" in
  amd64 | arm64) ;;
  *)
    echo "unknown arch: $ARCH" >&2
    exit 2
    ;;
esac

if [[ -z ${VERSION:-} || -z ${FILENAME:-} ]]; then
  # shellcheck disable=SC1090
  eval "$("$script_dir/resolve.py" --shell "$DISTRO" "$ARCH")"
fi

: "${VERSION:?}"
: "${CODENAME:?}"
: "${CHANNEL:?}"
: "${DISTRO_ARCH:?}"
: "${UNAME:?}"
: "${FILENAME:?}"
: "${QEMU:=}"
: "${UPSTREAM_URL:=}"
: "${UPSTREAM_SHA256:=}"

OUT=${OUT:-out}
mkdir -p "$OUT"

if [[ $(id -u) -eq 0 ]]; then
  SUDO=()
else
  if ! sudo -n true 2>/dev/null; then
    echo "this build needs root or passwordless sudo" >&2
    exit 1
  fi
  SUDO=(sudo -n)
fi

log() {
  printf '==> %s\n' "$*"
}

work=
root=
cleanup() {
  status=$?
  set +e
  if [[ -n $root && -d $root ]]; then
    for mp in sys proc dev run; do
      if mountpoint -q "$root/$mp" 2>/dev/null; then
        "${SUDO[@]}" umount "$root/$mp" || "${SUDO[@]}" umount -l "$root/$mp" || {
          echo "cleanup: $root/$mp is still mounted; leaving $work in place" >&2
          return 1
        }
      fi
    done
  fi
  if [[ -n $work && -d $work ]]; then
    "${SUDO[@]}" rm -rf "$work"
  fi
  return "$status"
}
trap cleanup EXIT

work=$(mktemp -d /tmp/boxrootfs.XXXXXX)
root=$work/rootfs

enable_universe() {
  if apt-cache show "$1" >/dev/null 2>&1; then
    return 0
  fi
  # Do not source os-release into this script: it would overwrite VERSION.
  local host_codename
  host_codename=$(. /etc/os-release && printf '%s\n' "$VERSION_CODENAME")
  echo "deb http://archive.ubuntu.com/ubuntu ${host_codename} universe" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/boxrootfs-universe.list >/dev/null
  "${SUDO[@]}" apt-get update
}

ensure_deps() {
  local pkgs=(ca-certificates curl xz-utils)
  if [[ $DISTRO == debian || $DISTRO == ubuntu ]]; then
    pkgs+=(mmdebstrap gpg debian-archive-keyring ubuntu-archive-keyring)
  fi
  if [[ $ARCH == arm64 ]]; then
    pkgs+=(qemu-user-static)
  fi
  log "installing host packages: ${pkgs[*]}"
  "${SUDO[@]}" apt-get update
  if [[ $DISTRO != alpine ]]; then
    enable_universe mmdebstrap
  fi
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${pkgs[@]}"
}

find_keyring() {
  local name=$1
  local path
  for path in "/usr/share/keyrings/${name}.gpg" "/usr/share/keyrings/${name}.pgp"; do
    if [[ -f $path ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  echo "missing keyring $name" >&2
  return 1
}

write_file() {
  local path=$1
  local mode=$2
  local tmp
  tmp=$(mktemp)
  cat >"$tmp"
  "${SUDO[@]}" install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

umount_build() {
  local mp
  for mp in sys proc dev run; do
    if [[ -d $root/$mp ]] && mountpoint -q "$root/$mp"; then
      "${SUDO[@]}" umount "$root/$mp"
    fi
  done
}

mount_build() {
  "${SUDO[@]}" mkdir -p "$root/dev" "$root/proc" "$root/sys"
  "${SUDO[@]}" mount --bind /dev "$root/dev"
  "${SUDO[@]}" mount --bind /proc "$root/proc"
  "${SUDO[@]}" mount --bind /sys "$root/sys"
}

finalize_rootfs() {
  local mp
  umount_build
  [[ $root == /tmp/boxrootfs.*/rootfs ]]
  [[ -d $root/etc ]]
  for mp in dev proc sys run; do
    if [[ -L $root/$mp ]]; then
      echo "refusing to replace symlinked $root/$mp" >&2
      exit 1
    fi
    if mountpoint -q "$root/$mp" 2>/dev/null; then
      echo "$root/$mp is still mounted" >&2
      exit 1
    fi
  done

  log "applying BoxKernel rootfs fixes"
  "${SUDO[@]}" rm -rf "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/tmp"
  "${SUDO[@]}" mkdir -p \
    "$root/dev" "$root/proc" "$root/sys" "$root/run" \
    "$root/tmp" "$root/var/tmp" "$root/root" "$root/home" "$root/etc"
  "${SUDO[@]}" chmod 755 "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/root" "$root/home"
  "${SUDO[@]}" chmod 1777 "$root/tmp" "$root/var/tmp"

  # Public resolvers. A symlink into systemd-resolved does not work under proot.
  "${SUDO[@]}" rm -f "$root/etc/resolv.conf"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | write_file "$root/etc/resolv.conf" 644
  printf '127.0.0.1\tlocalhost\n::1\tlocalhost ip6-localhost ip6-loopback\n' \
    | write_file "$root/etc/hosts" 644
  printf '%s\n' "$DISTRO" | write_file "$root/etc/hostname" 644

  if [[ -f $root/etc/machine-id ]]; then
    printf '' | write_file "$root/etc/machine-id" 644
  fi

  "${SUDO[@]}" rm -f "$root"/usr/bin/qemu-*-static

  if [[ $DISTRO == debian || $DISTRO == ubuntu ]]; then
    # Package installs must not try to start services; proot has no init.
    printf '#!/bin/sh\nexit 101\n' | write_file "$root/usr/sbin/policy-rc.d" 755
    "${SUDO[@]}" mkdir -p "$root/etc/apt/apt.conf.d" "$root/var/lib/apt/lists/partial"
    printf 'APT::Sandbox::User "root";\nAcquire::Retries "3";\n' \
      | write_file "$root/etc/apt/apt.conf.d/99boxkernel" 644
    printf 'LANG=C.UTF-8\n' | write_file "$root/etc/default/locale" 644
    if [[ -d $root/var/lib/apt/lists ]]; then
      "${SUDO[@]}" find "$root/var/lib/apt/lists" -type f -delete
    fi
    "${SUDO[@]}" rm -rf "$root/var/cache/apt/archives/"*.deb
  fi
  if [[ -d $root/var/cache/apk ]]; then
    "${SUDO[@]}" rm -rf "$root"/var/cache/apk/*
  fi

  local built
  built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  {
    printf 'distro=%s\n' "$DISTRO"
    printf 'channel=%s\n' "$CHANNEL"
    printf 'version=%s\n' "$VERSION"
    printf 'codename=%s\n' "$CODENAME"
    printf 'arch=%s\n' "$ARCH"
    printf 'distro_arch=%s\n' "$DISTRO_ARCH"
    printf 'uname=%s\n' "$UNAME"
    if [[ -n $QEMU ]]; then
      printf 'qemu=%s\n' "$QEMU"
    fi
    printf 'built=%s\n' "$built"
    printf 'generator=https://github.com/BoxOSLab/BoxRootfs\n'
  } | write_file "$root/etc/boxkernel-rootfs" 644
}

pack_rootfs() {
  local dest=$1
  log "packing $dest"
  "${SUDO[@]}" tar -C "$root" \
    --numeric-owner --owner=0 --group=0 \
    --sort=name \
    --exclude=./dev/'*' \
    --exclude=./proc/'*' \
    --exclude=./sys/'*' \
    --exclude=./run/'*' \
    --exclude=./tmp/'*' \
    --exclude=./var/tmp/'*' \
    -cf - . | xz -T0 -6 >"$dest.partial"
  mv "$dest.partial" "$dest"

  if ! tar -tJf "$dest" | grep -Eq '^\./(usr/)?bin/sh$'; then
    echo "archive is missing bin/sh" >&2
    exit 1
  fi
  if tar -tvJf "$dest" | awk 'substr($0, 1, 1) ~ /^[cb]/ { found = 1 } END { exit !found }'; then
    echo "archive contains device nodes" >&2
    exit 1
  fi
  if tar -tvJf "$dest" | awk '$0 ~ /resolv\.conf/ && substr($0, 1, 1) == "l" { found = 1 } END { exit !found }'; then
    echo "resolv.conf is still a symlink" >&2
    exit 1
  fi
}

write_meta() {
  local dest=$1
  local digest size
  digest=$(sha256sum "$dest" | awk '{print $1}')
  size=$(stat -c%s "$dest")
  export DISTRO CHANNEL VERSION CODENAME ARCH DISTRO_ARCH UNAME QEMU FILENAME
  export UPSTREAM_URL UPSTREAM_SHA256
  DEST="$dest" DIGEST="$digest" SIZE="$size" META="$dest.meta.json" python3 - <<'PY'
import json, os
meta = {
    "distro": os.environ["DISTRO"],
    "channel": os.environ["CHANNEL"],
    "version": os.environ["VERSION"],
    "codename": os.environ["CODENAME"],
    "arch": os.environ["ARCH"],
    "distro_arch": os.environ["DISTRO_ARCH"],
    "uname": os.environ["UNAME"],
    "qemu": os.environ.get("QEMU") or "",
    "filename": os.environ["FILENAME"],
    "sha256": os.environ["DIGEST"],
    "size": int(os.environ["SIZE"]),
}
if os.environ.get("UPSTREAM_SHA256"):
    meta["upstream_sha256"] = os.environ["UPSTREAM_SHA256"]
    meta["upstream_url"] = os.environ["UPSTREAM_URL"]
path = os.environ["META"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(meta, handle, indent=2)
    handle.write("\n")
print(f"{meta['filename']} {meta['sha256']} {meta['size']}")
PY
}

build_apt() {
  local keyring
  local -a mirrors
  if [[ $DISTRO == debian ]]; then
    keyring=$(find_keyring debian-archive-keyring)
    mirrors=(
      "deb https://deb.debian.org/debian ${CODENAME} main"
      "deb https://deb.debian.org/debian ${CODENAME}-updates main"
      "deb https://deb.debian.org/debian-security ${CODENAME}-security main"
    )
  else
    keyring=$(find_keyring ubuntu-archive-keyring)
    mirrors=(
      "deb https://archive.ubuntu.com/ubuntu ${CODENAME} main restricted"
      "deb https://archive.ubuntu.com/ubuntu ${CODENAME}-updates main restricted"
      "deb https://security.ubuntu.com/ubuntu ${CODENAME}-security main restricted"
    )
  fi
  log "mmdebstrap $DISTRO $CODENAME $ARCH"
  "${SUDO[@]}" mmdebstrap \
    --variant=minbase \
    --architectures="$ARCH" \
    --include=ca-certificates \
    --keyring="$keyring" \
    --aptopt='Acquire::Retries "5"' \
    --format=directory \
    "$CODENAME" \
    "$root" \
    "${mirrors[@]}"
}

build_alpine() {
  : "${UPSTREAM_URL:?}"
  : "${UPSTREAM_SHA256:?}"
  local tarball=$work/upstream.tar.gz
  log "downloading $UPSTREAM_URL"
  curl -fL --retry 5 --retry-delay 2 -o "$tarball" "$UPSTREAM_URL"
  echo "$UPSTREAM_SHA256  $tarball" | sha256sum -c -
  "${SUDO[@]}" mkdir -p "$root"
  "${SUDO[@]}" tar -C "$root" -xzf "$tarball"
  # apk runs inside the guest and needs a resolver plus /dev.
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | write_file "$root/etc/resolv.conf" 644
  mount_build
  local -a apk=(/sbin/apk)
  if [[ $ARCH == arm64 ]]; then
    if [[ ! -x /usr/bin/qemu-aarch64-static ]]; then
      echo "qemu-aarch64-static is not installed" >&2
      exit 1
    fi
    "${SUDO[@]}" cp /usr/bin/qemu-aarch64-static "$root/usr/bin/qemu-aarch64-static"
    apk=(/usr/bin/qemu-aarch64-static /sbin/apk)
  fi
  log "apk add ca-certificates"
  "${SUDO[@]}" chroot "$root" "${apk[@]}" add --no-cache ca-certificates
  umount_build
  "${SUDO[@]}" rm -f "$root/usr/bin/qemu-aarch64-static"
}

ensure_deps
case "$DISTRO" in
  debian | ubuntu) build_apt ;;
  alpine) build_alpine ;;
esac
finalize_rootfs
pack_rootfs "$OUT/$FILENAME"
write_meta "$OUT/$FILENAME"
log "done $OUT/$FILENAME"
