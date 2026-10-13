#!/usr/bin/env python3
"""Builds mosalua_patcher.py: the patcher, mosalua.hdll and the mods folder in one file.
Uses build/win/mosalua.hdll if ../build.sh has been run, else prebuilt/mosalua.hdll.
usage: build_standalone.py [output file]  The payload is a zip (patcher/*.py, game_files/...) in base64."""
import base64, io, os, re, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "patcher"))
import mosalua_patch as MP

version = re.search(r'#define MOSALUA_VERSION "([^"]+)"', open(os.path.join(ROOT, "src", "mosalua.c")).read()).group(1)
kit = re.search(r'ml\.version = "([^"]+)"', open(os.path.join(ROOT, "mods", "_lib", "mosalina.lua")).read()).group(1)
buf = io.BytesIO()
FIXED = (2026, 1, 1, 0, 0, 0)      # fixed dates: the same sources give the same file
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    def add(arc, path):
        info = zipfile.ZipInfo(arc, FIXED)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(path, "rb") as fh:
            z.writestr(info, fh.read())
    for f in ("hlbc.py", "mosalua_patch.py", "mosalua_install.py", "install.py"):
        add("patcher/" + f, os.path.join(ROOT, "patcher", f))
    hdll = os.path.join(ROOT, "build", "win", "mosalua.hdll")
    if not os.path.exists(hdll):
        hdll = os.path.join(ROOT, "prebuilt", "mosalua.hdll")
    add("game_files/mosalua.hdll", hdll)
    entries = {}
    mods = os.path.join(ROOT, "mods")
    for root, dirs, files in os.walk(mods):
        for f in files:
            full = os.path.join(root, f)
            entries["game_files/mods/" + os.path.relpath(full, mods).replace(os.sep, "/")] = full
    ex = os.path.join(ROOT, "examples")
    for f in os.listdir(ex):
        if f.endswith(".lua"):
            entries["game_files/mods/_examples/" + f] = os.path.join(ex, f)
    for arc in sorted(entries):
        add(arc, entries[arc])
    add("game_files/mods/_docs/README.md", os.path.join(ROOT, "docs", "GUIDE.md"))
    add("game_files/mods/_docs/API.md", os.path.join(ROOT, "docs", "API.md"))
b64 = base64.b64encode(buf.getvalue()).decode()
payload = "\n".join(b64[i:i + 100] for i in range(0, len(b64), 100))
src = open(os.path.join(HERE, "template.py"), encoding="utf-8").read()
src = src.replace("@VERSION@", kit).replace("@RUNTIME@", version).replace("@MARKER@", MP.MARKER).replace("@PAYLOAD@", payload)
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "mosalua_patcher.py")
with open(out, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(src)
print("%s: %d bytes, payload %d bytes zipped, kit %s, runtime %s" % (out, len(src), len(buf.getvalue()), kit, version))
