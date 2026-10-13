#!/usr/bin/env python3
"""Install (or remove) the Lua modding runtime in a HashLink game folder.

    python install.py "C:\\...\\steamapps\\common\\Mosa Lina"
    python install.py "C:\\...\\Mosa Lina" --uninstall

Run it AFTER any other tool that rewrites hlboot.dat: the Lua patch must be
the last step, because it shifts code inside the functions it makes hookable.
Re-running is safe: the pre-Lua file is kept as hlboot.dat.pre_lua.
"""
import argparse
import os
import shutil
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mosalua_patch as MP
import mosalua_install as MI

def find_file(folder, name):
    for root, _dirs, files in os.walk(folder):
        for f in files:
            if f.lower() == name:
                return os.path.join(root, f)
    return None


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", help="game folder (or the hlboot.dat inside it)")
    ap.add_argument("--uninstall", action="store_true", help="restore the pre-Lua hlboot.dat")
    ap.add_argument("--all", action="store_true", help="make engine and standard library functions hookable too")
    ap.add_argument("--include", action="append", default=[], help="extra hookable pattern, e.g. h2d.Object.*")
    ap.add_argument("--exclude", action="append", default=[], help="pattern to leave untouched")
    ap.add_argument("--natives", metavar="LIBS", help="comma separated native libraries whose functions become "
                    "hookable (default: %s; every native is callable from Lua either way)" % ",".join(MP.DEFAULT_NATIVE_HOOKS))
    a = ap.parse_args(argv)

    boot = a.game if os.path.isfile(a.game) else find_file(a.game, "hlboot.dat")
    if not boot:
        print("error: no hlboot.dat found in %s" % a.game)
        return 1
    folder = os.path.dirname(os.path.abspath(boot))
    backup = boot + ".pre_lua"

    if a.uninstall:
        if not os.path.exists(backup):
            print("error: %s not found, nothing to restore" % backup)
            return 1
        shutil.copyfile(backup, boot)
        print("restored %s (mods folder and mosalua.hdll left in place; they are inert now)" % boot)
        return 0

    with open(boot, "rb") as fh:
        data = fh.read()
    if MP.MARKER.encode() in data:
        if not os.path.exists(backup):
            print("error: hlboot.dat already has the Lua patch and there is no %s to rebuild from.\n"
                  "Restore the original file (Steam: verify integrity) and run this again." % os.path.basename(backup))
            return 1
        print("hlboot.dat already has the Lua patch: rebuilding from %s" % os.path.basename(backup))
        with open(backup, "rb") as fh:
            data = fh.read()
    else:
        shutil.copyfile(boot, backup)
        print("kept the current file as %s" % os.path.basename(backup))

    ok, msg = MI.check_libhl(folder)
    if ok is False:
        print("error: %s\nNothing was changed. Send this message along so the runtime can be adapted." % msg)
        return 1
    if ok is None:
        print("warning: " + msg)

    exclude = ([] if a.all else list(MP.DEFAULT_EXCLUDE)) + a.exclude
    try:
        native_hooks = None
        if a.natives:
            native_hooks = [] if a.natives == "none" else [x.strip() for x in a.natives.split(",") if x.strip()]
        out, info = MP.patch(data, include=MP.DEFAULT_INCLUDE + a.include, exclude=exclude, native_hooks=native_hooks)
    except (MP.PatchError, ValueError) as e:
        print("error: %s\nNothing was changed." % e)
        return 1
    with open(boot, "wb") as fh:
        fh.write(out)

    files = os.path.join(os.path.dirname(HERE), "game_files")
    for note in MI.install_runtime(folder, files, info=info):
        print(note)
    mods = os.path.join(folder, "mods")
    print("\nDone. %d game functions are hookable (full list: mods%shookable.txt)." % (len(info["hooks"]), os.sep))
    print("Mods go in %s" % mods)
    print("Start the game, then read mods%smosalua.log to see what loaded." % os.sep)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
