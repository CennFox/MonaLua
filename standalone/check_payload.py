#!/usr/bin/env python3
"""Fails if mosalua_patcher.py is not what build_standalone.py makes from the files in the
repository (someone changed mods/, examples/, docs/ or patcher/ without rebuilding it)."""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
with tempfile.TemporaryDirectory() as tmp:
    fresh = os.path.join(tmp, "mosalua_patcher.py")
    subprocess.run([sys.executable, os.path.join(HERE, "build_standalone.py"), fresh], check=True, stdout=subprocess.DEVNULL)
    same = open(fresh, "rb").read() == open(os.path.join(ROOT, "mosalua_patcher.py"), "rb").read()
if not same:
    sys.exit("mosalua_patcher.py is out of date: run  python standalone/build_standalone.py  and commit the result")
print("mosalua_patcher.py is up to date")
