#!/usr/bin/env python3
"""Builds the Alpine aarch64 rootfs that ships inside the DSH iOS app.

The rootfs has to be converted with fakefsify *after* every file is in place:
iSH's fakefs looks paths up in meta.db, so files copied in after conversion are
invisible to the guest. This script therefore assembles a staging tree, creates
one tar.gz from it, and only then runs fakefsify.

Inputs (all pinned in tools/alpine-rootfs-lock.json):
  - Alpine minirootfs 3.23.0 aarch64
  - the aarch64 apk closure of nodejs + npm, extracted without executing guest
    code (the build host cannot run Linux aarch64 binaries)
  - a host-built DSH node_modules tree (tools/build-dsh-tree.sh)

Usage:
  prepare-dsh-rootfs.py --dsh-tree DIR --output DIR [--work DIR]
                        [--fakefsify PATH] [--keep-work]
"""

import argparse
import hashlib
import io
import json
import os
import shutil
import sqlite3
import stat
import sys
import tarfile
import tempfile
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK_PATH = os.path.join(HERE, "alpine-rootfs-lock.json")
SOURCE_DATE_EPOCH = 1767225600  # 2026-01-01T00:00:00Z
MIRRORS = [
    "https://mirrors.tuna.tsinghua.edu.cn/alpine",
    "https://dl-cdn.alpinelinux.org/alpine",
]


def log(message):
    print("[rootfs] " + message, flush=True)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, destination, expected_sha256):
    if os.path.exists(destination) and sha256_file(destination) == expected_sha256:
        return
    errors = []
    candidates = [url] + [u for u in (url.replace(MIRRORS[0], m) for m in MIRRORS) if u != url]
    for candidate in candidates:
        try:
            log("fetch " + candidate)
            temporary = destination + ".part"
            with urllib.request.urlopen(candidate, timeout=120) as response, open(temporary, "wb") as out:
                shutil.copyfileobj(response, out)
            actual = sha256_file(temporary)
            if actual != expected_sha256:
                errors.append("%s: sha256 %s != %s" % (candidate, actual, expected_sha256))
                os.unlink(temporary)
                continue
            os.replace(temporary, destination)
            return
        except Exception as error:  # network errors fall through to the next mirror
            errors.append("%s: %s" % (candidate, error))
    raise SystemExit("download failed:\n  " + "\n  ".join(errors))


def extract_tar(source, destination, label):
    if isinstance(source, str):
        archive = tarfile.open(source, "r:*")
    else:
        archive = tarfile.open(fileobj=source, mode="r:")
    with archive:
        try:
            archive.extractall(destination, filter="fully_trusted")
        except TypeError:  # Python < 3.12 has no filter argument
            archive.extractall(destination)
    log("extracted " + label)


def gzip_members(data):
    """Yields each gzip member's decompressed bytes (apk files concatenate 3)."""
    position = 0
    while position < len(data):
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        chunk = decompressor.decompress(data[position:]) + decompressor.flush()
        yield chunk
        if not decompressor.unused_data:
            return
        position = len(data) - len(decompressor.unused_data)


def extract_apk(path, destination):
    with open(path, "rb") as handle:
        data = handle.read()
    members = list(gzip_members(data))
    if not members:
        raise SystemExit("empty apk: " + path)
    # apk v2 = signature tar.gz + control tar.gz + data tar.gz
    extract_tar(io.BytesIO(members[-1]), destination, os.path.basename(path))


def write_file(path, content, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.lexists(path):
        os.unlink(path)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(path, mode)


def copy_tree(source, destination):
    if os.path.exists(destination):
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True, copy_function=shutil.copy2)


def build_payload(staging, dsh_tree, lock):
    minirootfs = os.path.join(WORK_DIR, lock["alpine"]["minirootfs"])
    extract_tar(minirootfs, staging, lock["alpine"]["minirootfs"])

    for package in lock["packages"]:
        filename = "%s-%s.apk" % (package["name"], package["version"])
        path = os.path.join(WORK_DIR, filename)
        extract_apk(path, staging)

    # The DSH tree lives at /opt/dsh/node_modules, mirroring a global install.
    copy_tree(os.path.join(dsh_tree, "node_modules"), os.path.join(staging, "opt", "dsh", "node_modules"))

    write_file(
        os.path.join(staging, "usr", "local", "bin", "dsh"),
        "#!/bin/sh\nexec /usr/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js \"$@\"\n",
        0o755,
    )
    # npm's own launcher is a symlink into /usr/lib/node_modules/npm.
    if not os.path.lexists(os.path.join(staging, "usr", "bin", "npm")):
        os.symlink("../lib/node_modules/npm/bin/npm-cli.js", os.path.join(staging, "usr", "bin", "npm"))

    os.makedirs(os.path.join(staging, "root", ".dsh"), exist_ok=True)
    os.makedirs(os.path.join(staging, "tmp"), exist_ok=True)
    os.chmod(os.path.join(staging, "tmp"), 0o1777)
    os.makedirs(os.path.join(staging, "dev"), exist_ok=True)
    os.makedirs(os.path.join(staging, "proc"), exist_ok=True)
    os.makedirs(os.path.join(staging, "run"), exist_ok=True)

    write_file(
        os.path.join(staging, "etc", "resolv.conf"),
        "nameserver 8.8.8.8\nnameserver 8.8.4.4\n",
    )
    write_file(
        os.path.join(staging, "etc", "hosts"),
        "127.0.0.1 localhost localhost.localdomain\n::1 localhost\n",
    )
    write_file(
        os.path.join(staging, "etc", "profile"),
        "\n".join([
            "export HOME=/root",
            "export TERM=xterm-256color",
            "export LANG=C.UTF-8",
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "export DSH_HOME=/root/.dsh",
            "export NODE_OPTIONS=--dns-result-order=ipv4first",
            "export UV_USE_IO_URING=0",
            "export NARB_DISABLE_NATIVE_CACHE=1",
            "",
            "cd ~",
            "",
        ]),
    )
    write_file(
        os.path.join(staging, "etc", "dsh-image"),
        "dsh=%s\nalpine=%s\n" % (DSH_VERSION, lock["alpine"]["version"]),
    )


def create_tar(staging, archive_path):
    directories = []
    for root, dirs, files in os.walk(staging):
        dirs.sort()
        files.sort()
        directories.append((root, dirs, files))
    with tarfile.open(archive_path, "w:gz", compresslevel=6) as archive:
        for root, dirs, files in directories:
            for name in dirs + files:
                path = os.path.join(root, name)
                arcname = os.path.relpath(path, staging)
                info = tarfile.TarInfo(arcname)
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = SOURCE_DATE_EPOCH
                st = os.lstat(path)
                info.mode = stat.S_IMODE(st.st_mode)
                if stat.S_ISLNK(st.st_mode):
                    info.type = tarfile.SYMTYPE
                    info.linkname = os.readlink(path)
                    archive.addfile(info)
                elif stat.S_ISDIR(st.st_mode):
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
                elif stat.S_ISREG(st.st_mode):
                    info.type = tarfile.REGTYPE
                    info.size = st.st_size
                    with open(path, "rb") as handle:
                        archive.addfile(info, handle)
                elif stat.S_ISFIFO(st.st_mode):
                    info.type = tarfile.FIFOTYPE
                    archive.addfile(info)
                else:
                    log("skipping special file " + arcname)


def verify(fakefs, dsh_tree):
    database = os.path.join(fakefs, "meta.db")
    data_root = os.path.join(fakefs, "data")
    connection = sqlite3.connect(database)
    try:
        rows = connection.execute("select path, stats.stat from paths join stats on stats.inode = paths.inode").fetchall()
    finally:
        connection.close()
    stats = {}
    for path, blob in rows:
        if isinstance(path, bytes):
            path = path.decode("utf-8", "replace")
        stats[path] = blob
    required = [
        "/usr/bin/node",
        "/usr/lib/node_modules/npm/bin/npm-cli.js",
        "/usr/local/bin/dsh",
        "/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "/opt/dsh/node_modules/@koromix/koffi-linux-arm64/musl_arm64/koffi.node",
        "/etc/resolv.conf",
        "/root/.dsh",
    ]
    missing = [path for path in required if path not in stats]
    if missing:
        raise SystemExit("meta.db is missing: " + ", ".join(missing))
    for path in ("/usr/bin/node", "/usr/local/bin/dsh"):
        mode = int.from_bytes(stats[path][:4], "little")
        if mode & stat.S_IXUSR == 0:
            raise SystemExit("%s is not executable in meta.db (mode 0o%o)" % (path, mode))
    node_host = os.path.join(data_root, "usr/bin/node")
    if not os.path.isfile(node_host) or os.path.getsize(node_host) < 1_000_000:
        raise SystemExit("data/usr/bin/node is missing or truncated")
    dsh_host = os.path.join(data_root, "opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
    if not os.path.isfile(dsh_host):
        raise SystemExit("data/.../bin.js is missing")
    expected_packages = len(
        [
            name
            for name in os.listdir(os.path.join(dsh_tree, "node_modules"))
            if not name.startswith(".")
        ]
    )
    total = 0
    for root, _dirs, files in os.walk(data_root):
        for name in files:
            path = os.path.join(root, name)
            if os.path.isfile(path):
                total += os.path.getsize(path)
    log("meta.db: %d paths, %d packages, node=%d bytes, data=%s" % (
        len(stats),
        expected_packages,
        os.path.getsize(node_host),
        human(total),
    ))


def main():
    global WORK_DIR, DSH_VERSION
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsh-tree", required=True, help="output of build-dsh-tree.sh")
    parser.add_argument("--output", required=True, help="fakefs output directory")
    parser.add_argument("--work", help="cache/download directory (default: temp dir)")
    parser.add_argument("--fakefsify", help="path to the fakefsify binary (skip conversion when omitted)")
    parser.add_argument("--keep-work", action="store_true")
    parser.add_argument("--mirror", action="append", help="Alpine mirror root (repeatable)")
    args = parser.parse_args()

    if args.mirror:
        MIRRORS[:] = args.mirror

    with open(LOCK_PATH, encoding="utf-8") as handle:
        lock = json.load(handle)
    DSH_VERSION = json.load(open(os.path.join(HERE, "dsh-lock", "package.json")))["dependencies"]["@deepseek-ai/dsh"]

    WORK_DIR = args.work or tempfile.mkdtemp(prefix="dsh-rootfs-")
    os.makedirs(WORK_DIR, exist_ok=True)
    log("work directory " + WORK_DIR)

    alpine = lock["alpine"]
    download(
        "%s/%s/releases/%s/%s" % (MIRRORS[0], alpine["mirror_path"], alpine["arch"], alpine["minirootfs"]),
        os.path.join(WORK_DIR, alpine["minirootfs"]),
        alpine["minirootfs_sha256"],
    )
    for package in lock["packages"]:
        filename = "%s-%s.apk" % (package["name"], package["version"])
        download(
            "%s/%s/%s/%s/%s" % (MIRRORS[0], alpine["mirror_path"], package["repo"], alpine["arch"], filename),
            os.path.join(WORK_DIR, filename),
            package["sha256"],
        )

    staging = os.path.join(WORK_DIR, "staging")
    if os.path.exists(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)

    build_payload(staging, args.dsh_tree, lock)
    archive_path = os.path.join(WORK_DIR, "dsh-rootfs.tar.gz")
    create_tar(staging, archive_path)
    log("archive %s (%s)" % (archive_path, human(os.path.getsize(archive_path))))

    if args.fakefsify:
        if os.path.exists(args.output):
            shutil.rmtree(args.output)
        log("fakefsify -> " + args.output)
        import subprocess
        subprocess.run([args.fakefsify, archive_path, args.output], check=True)
        verify(args.output, args.dsh_tree)
    else:
        log("skipping fakefsify (no --fakefsify given)")

    if not args.keep_work and not args.work:
        shutil.rmtree(WORK_DIR, ignore_errors=True)


def human(size):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return "%.1f %s" % (size, unit)
        size /= 1024


if __name__ == "__main__":
    sys.exit(main())
