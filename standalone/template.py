#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""Mosa Lina Lua mods: standalone patcher @VERSION@ (runtime @RUNTIME@).

One file. Needs Python 3.6 or later and nothing else.

    double-click mosalua_patcher.py              finds the game, asks, patches
    python mosalua_patcher.py "<game folder>"     the same for that folder
                                                  (or drag the folder onto this file)
    python mosalua_patcher.py --uninstall ["<game folder>"]
                                                  puts the pre-Lua hlboot.dat back

What it does in the game folder:

    hlboot.dat        patched; the file it replaces is kept as hlboot.dat.pre_lua
    mosalua.hdll      added: the Lua runtime
    mods\             added: your .lua mods go here.  _lib, _examples and _docs in it
                      are refreshed on every run; nothing else is ever overwritten

Close the game first.  Run this again after a game update, and after using any other
patcher on hlboot.dat (the Lua patch has to be the last one).  Running it twice is safe.

Options: -y  do not ask and do not wait for Enter      --natives LIBS, --all  see below
"""
import base64
import io
import os
import re
import shutil
import sys
import tempfile
import zipfile

VERSION = "@VERSION@"
RUNTIME = "@RUNTIME@"
MARKER = b"@MARKER@"


def say(text=""):
    try:
        print(text)
    except UnicodeEncodeError:      # a console that cannot show a path's characters
        print(text.encode("ascii", "replace").decode("ascii"))
    sys.stdout.flush()


def steam_libraries():
    """Folders that may hold steamapps\\common."""
    roots = []
    if os.name == "nt":
        try:
            import winreg
            for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                              (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
                              (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam")):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        for name in ("SteamPath", "InstallPath"):
                            try:
                                roots.append(winreg.QueryValueEx(k, name)[0])
                            except OSError:
                                pass
                except OSError:
                    pass
        except ImportError:
            pass
        for env in ("ProgramFiles(x86)", "ProgramFiles"):
            if os.environ.get(env):
                roots.append(os.path.join(os.environ[env], "Steam"))
    else:
        home = os.path.expanduser("~")
        roots += [os.path.join(home, ".steam", "steam"), os.path.join(home, ".local", "share", "Steam"),
                  os.path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
                  os.path.join(home, "Library", "Application Support", "Steam")]
    libs = []
    for root in roots:
        libs.append(root)
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        try:
            with open(vdf, encoding="utf-8", errors="replace") as fh:
                for m in re.finditer(r'"path"\s+"([^"]+)"', fh.read()):
                    libs.append(m.group(1).replace("\\\\", "\\"))
        except OSError:
            pass
    seen, out = set(), []
    for lib in libs:
        key = os.path.normcase(os.path.normpath(lib))
        if key not in seen and os.path.isdir(lib):
            seen.add(key)
            out.append(lib)
    return out


def find_boot(path):
    """hlboot.dat for a path that is the file itself, the game folder, or a folder above it."""
    path = path.strip()
    if path.startswith("& "):           # PowerShell writes a dragged path as & 'C:\...'
        path = path[2:].strip()
    path = path.strip('"').strip("'")
    if os.path.isfile(path):
        if os.path.basename(path).lower() == "hlboot.dat":
            return path
        path = os.path.dirname(os.path.abspath(path))     # some other file of the game was given
    if not os.path.isdir(path):
        return None
    direct = os.path.join(path, "hlboot.dat")
    if os.path.isfile(direct):
        return direct
    base = path.rstrip("\\/").count(os.sep)
    for root, dirs, files in os.walk(path):
        if root.count(os.sep) - base >= 3:
            dirs[:] = []
        for f in files:
            if f.lower() == "hlboot.dat":
                return os.path.join(root, f)
    return None


def find_installed():
    found = []
    for lib in steam_libraries():
        common = os.path.join(lib, "steamapps", "common")
        try:
            names = os.listdir(common)
        except OSError:
            continue
        for name in names:
            low = name.lower()
            if "mosa" in low and "lina" in low:
                boot = find_boot(os.path.join(common, name))
                if boot:
                    found.append(boot)
    return found


def ask(question, choices, default):
    """One letter from choices; Enter gives the default."""
    while True:
        try:
            answer = input(question + " ").strip().lower()
        except EOFError:
            return default
        if not answer:
            return default
        if answer[0] in choices:
            return answer[0]


def locate(given, interactive):
    if given:
        boot = find_boot(given)
        if not boot:
            say("No hlboot.dat found in: %s" % given)
        return boot
    here = os.path.dirname(os.path.abspath(__file__))
    for folder in (here, os.getcwd()):
        direct = os.path.join(folder, "hlboot.dat")
        if os.path.isfile(direct):
            return direct
    found = find_installed()
    if len(found) == 1:
        return found[0]
    if len(found) > 1 and interactive:
        say("Found more than one copy of the game:")
        for i, boot in enumerate(found):
            say("  %d  %s" % (i + 1, os.path.dirname(boot)))
        pick = ask("Which one? [1-%d]" % len(found), "123456789"[:len(found)], "1")
        return found[int(pick) - 1]
    if found:
        return found[0]
    if not interactive:
        say("Could not find the game. Give the game folder: python mosalua_patcher.py \"<game folder>\"")
        return None
    say("Could not find the game by itself.")
    say("In Steam: right-click Mosa Lina > Manage > Browse local files, then drag that folder")
    say("(or the hlboot.dat in it) into this window and press Enter.")
    while True:
        try:
            line = input("> ").strip()
        except EOFError:
            return None
        if not line:
            return None
        boot = find_boot(line)
        if boot:
            return boot
        say("No hlboot.dat in there. Try again, or just press Enter to quit.")


def unpack(tmp):
    with zipfile.ZipFile(io.BytesIO(base64.b64decode(PAYLOAD))) as z:
        z.extractall(tmp)


def run(argv):
    opts = [a for a in argv if a.startswith("-")]
    paths = [a for a in argv if not a.startswith("-")]
    if "-h" in opts or "--help" in opts:
        say(__doc__)
        say("--natives LIBS   comma separated native libraries whose functions become hookable")
        say("                 (default: fish, the physics library; every native is callable anyway)")
        say("--all            make engine and standard library functions hookable too")
        return 0, False
    yes = "-y" in opts or "--yes" in opts
    uninstall = "--uninstall" in opts
    passthrough = []
    i = 0
    while i < len(argv):
        if argv[i] == "--natives" and i + 1 < len(argv):
            passthrough += argv[i:i + 2]
            if argv[i + 1] in paths:
                paths.remove(argv[i + 1])
            i += 1
        elif argv[i] == "--all":
            passthrough.append("--all")
        i += 1
    interactive = (not yes) and sys.stdin is not None and sys.stdin.isatty()

    say("Mosa Lina Lua mods, patcher %s (runtime %s)" % (VERSION, RUNTIME))
    say()
    boot = locate(paths[0] if paths else None, interactive)
    if not boot:
        return 1, interactive
    boot = os.path.abspath(boot)
    folder = os.path.dirname(boot)
    backup = boot + ".pre_lua"
    with open(boot, "rb") as fh:
        patched = MARKER in fh.read()
    say("Game folder: %s" % folder)
    say("hlboot.dat:  %s" % ("has the Lua patch" if patched else "no Lua patch yet"))
    say()

    if interactive and not uninstall:
        if patched and os.path.exists(backup):
            pick = ask("[U]pdate the patch and the runtime, [R]emove the patch, or [C]ancel? [U]", "urc", "u")
            if pick == "c":
                return 0, interactive
            uninstall = pick == "r"
        elif not patched:
            if ask("Patch this game? [Y/n]", "yn", "y") == "n":
                return 0, interactive
        say()

    tmp = tempfile.mkdtemp(prefix="mosalua_")
    try:
        unpack(tmp)
        sys.path.insert(0, os.path.join(tmp, "patcher"))
        import install
        import mosalua_install
        if not uninstall and mosalua_install.check_libhl(folder)[0]:
            say("libhl.dll has everything the Lua runtime needs")
        try:
            code = install.main([boot] + (["--uninstall"] if uninstall else passthrough))
        except PermissionError as e:
            say("error: could not write %s" % (e.filename or "a file in the game folder"))
            say("Is the game still running? Close it and run this again.")
            code = 1
        except OSError as e:
            say("error: %s" % e)
            code = 1
        if code == 0 and not uninstall:
            say("The guide and the API reference are in mods%s_docs." % os.sep)
            say("To undo: run this again and choose Remove (or use --uninstall).")
        return code, interactive
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if sys.version_info < (3, 6):
        print("This needs Python 3.6 or later.")
        return 1
    try:
        code, wait = run(sys.argv[1:])
    except KeyboardInterrupt:
        code, wait = 1, False
    except Exception:
        import traceback
        traceback.print_exc()
        say("\nSomething went wrong inside the patcher. Please send the text above along.")
        code, wait = 1, sys.stdin is not None and sys.stdin.isatty() and "-y" not in sys.argv
    if wait:
        try:
            input("\nPress Enter to close.")
        except EOFError:
            pass
    return code


PAYLOAD = """
@PAYLOAD@
"""

if __name__ == "__main__":
    sys.exit(main())
