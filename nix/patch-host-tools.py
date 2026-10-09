"""Patch Google's Linux x86-64 host tools, optionally wrapping them with QEMU.

Target sysroots/compiler runtimes and symlink aliases must remain intact.
Uses argv-based subprocess calls; no shell interpolation of discovered paths.
"""
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys

# The real driver binary is clang-<major>; clang and clang++ are symlinks to it.
CLANG_DRIVER = re.compile(r"^clang(-\d+)?$")


def main():
    root, loader, libraries, qemu, shell = sys.argv[1:]
    # Nix passes $out literally through a quoted argument.
    root = Path(root.replace("$out", os.environ["out"]))
    count = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        # lib/clang contains TARGET runtime objects, not host libraries.
        dirs[:] = [
            d for d in dirs
            if d not in ("sysroot", "clang", "renderscript", "i386-unknown-linux-gnu")
            and "musl" not in d
        ]
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                header = stream.read(20)
            if len(header) < 20 or header[:4] != b"\x7fELF":
                continue
            if header[4:6] != b"\x02\x01":
                raise RuntimeError(f"Unexpected non-ELF64-LE host file: {path}")
            kind, machine = struct.unpack_from("<HH", header, 16)
            if machine != 62 or kind not in (2, 3):
                continue
            interp = subprocess.run(
                ["patchelf", "--print-interpreter", str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
            old_rpath = subprocess.run(
                ["patchelf", "--print-rpath", str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
            # Retain the NDK's own bundled host libraries before fallbacks.
            rpath = ":".join(filter(None, [
                old_rpath.stdout.strip(), "$ORIGIN", "$ORIGIN/../lib64",
                "$ORIGIN/../lib", libraries,
            ]))
            if old_rpath.returncode == 0:
                subprocess.run(["patchelf", "--set-rpath", rpath, str(path)], check=True)
            if interp.returncode == 0:
                subprocess.run(
                    ["patchelf", "--set-interpreter", loader, str(path)], check=True,
                )
            if qemu and (interp.returncode == 0 or kind == 2):
                real = path.with_name(f".{name}.google-elf")
                path.rename(real)
                # -0 preserves clang++ / llvm-ar multicall behaviour through
                # symlinks. All host ELF tools are wrapped, including ld.lld.
                run = (
                    f"exec {shlex.quote(qemu)} -U LD_LIBRARY_PATH -U LD_PRELOAD "
                    f'-0 "$0" {shlex.quote(str(real))}'
                )
                if CLANG_DRIVER.match(name):
                    # The clang driver spawns children (cc1as for assembly
                    # files, crash-report preprocessing) by re-executing its
                    # own binary, which it locates through /proc/self/exe:
                    # under QEMU that is the raw x86-64 ELF, so the child
                    # bypasses this wrapper and the kernel refuses it (or
                    # hands it to whatever binfmt handler the host has).
                    # -no-canonical-prefixes makes clang use argv[0], i.e.
                    # this wrapper, for its children. It must not precede
                    # the -cc1/-cc1as mode flags, which have to be argv[1].
                    script = (
                        f"#!{shell}\n"
                        'case "$1" in\n'
                        f'  -cc1|-cc1as|-cc1gen-reproducer) {run} "$@" ;;\n'
                        f'  *) {run} -no-canonical-prefixes "$@" ;;\n'
                        "esac\n"
                    )
                else:
                    script = f"#!{shell}\n{run} \"$@\"\n"
                path.write_text(script)
                path.chmod(0o755)
            count += 1
    print(f"Patched {count} host ELF files under {root}")


if __name__ == "__main__":
    main()
