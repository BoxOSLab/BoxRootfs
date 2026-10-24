# BoxRootfs

[![Rootfs](https://github.com/BoxOSLab/BoxRootfs/actions/workflows/rootfs.yml/badge.svg)](https://github.com/BoxOSLab/BoxRootfs/actions/workflows/rootfs.yml)

Automated guest root filesystems for [BoxKernel](https://github.com/BoxOSLab/BoxKernel).

Each build publishes the current stable release of three distributions, for `amd64` and `arm64`:

| Distro | What "stable" means | How the version is chosen |
|---|---|---|
| Debian | `stable` | `dists/stable/Release` on deb.debian.org |
| Ubuntu | newest LTS | last `Supported: 1` entry in `meta-release-lts` |
| Alpine | `latest-stable` | upstream `alpine-minirootfs` |

Debian and Ubuntu images are `minbase` plus `apt` and `ca-certificates`. Alpine starts from the upstream minirootfs and adds `ca-certificates`. They are not full desktop systems. Install more packages afterwards with `apt` or `apk`.

The rootfs contents stay under each distribution's own licenses. The build scripts in this repository are MIT.

## Download

`latest.json` on `main` lists the current files, checksums, and release URLs.

```console
$ git clone https://github.com/BoxOSLab/BoxRootfs.git
$ cd BoxRootfs
$ ./scripts/fetch.sh alpine amd64
$ proot -r rootfs/alpine-amd64 /bin/sh
$ proot -0 -r rootfs/alpine-amd64 /bin/sh
```

`proot` is the BoxKernel binary. `-0` makes package managers see uid 0.

`fetch.sh` accepts `amd64`/`arm64` (or `x86_64`/`aarch64`). For a foreign architecture it prints the matching `-q` value, for example `-q qemu-aarch64`.

To pick a file by hand, open the newest [release](https://github.com/BoxOSLab/BoxRootfs/releases), check `SHA256SUMS`, and extract as a normal user:

```console
$ mkdir rootfs
$ tar -C rootfs -xJf debian-13.7-trixie-amd64.tar.xz
```

The filename embeds the version resolved for that build. `latest.json` is the stable way to find the current name.

## What is changed for BoxKernel

Archives are repacked so a normal user can extract them:

* `/dev`, `/proc`, `/sys`, `/run`, and `/tmp` are empty directories. There are no device nodes.
* `/etc/resolv.conf` is a regular file with public resolvers, not a symlink into systemd-resolved.
* Debian and Ubuntu carry `/usr/sbin/policy-rc.d` exiting 101, so package installs do not try to start services.
* Debian and Ubuntu set `APT::Sandbox::User "root"` because the `_apt` sandbox user does not work under proot.
* `/etc/boxkernel-rootfs` records the distro, version, architecture, and build time.

Alpine tarballs are verified against the upstream SHA256 before those changes. The published checksum is of the repacked archive.

## Automation

[`.github/workflows/rootfs.yml`](.github/workflows/rootfs.yml) runs every Monday at 04:17 UTC, on changes to `scripts/` or the workflow, and from the Actions tab (`workflow_dispatch`). One failing image does not cancel the others. A release is published only when every requested image succeeds.

`workflow_dispatch` can limit the run to one distro or one architecture. The scheduled run builds all six.

Releases are immutable and named `YYYY.MM.DD`, with a numeric suffix if that tag already exists. The same run commits a new `latest.json` to `main`.
