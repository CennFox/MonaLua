"""Puts the Lua runtime's files into a game folder.  Shared by the patcher GUI and install.py."""
import os
import shutil
import struct

# what mosalua.hdll imports from the game's libhl.dll
REQUIRED = ["hl_add_root", "hl_alloc_array", "hl_alloc_closure_ptr", "hl_alloc_dynamic", "hl_alloc_dynbool",
            "hl_alloc_dynobj", "hl_alloc_enum", "hl_alloc_obj", "hl_alloc_strbytes", "hl_dyn_call_safe",
            "hl_dyn_castd", "hl_gc_alloc_gen", "hl_get_closure_value", "hl_get_obj_rt", "hl_get_thread",
            "hl_hash_gen", "hl_hash_utf8", "hl_hbget", "hl_hbkeys", "hl_make_dyn", "hl_make_var_args",
            "hl_no_closure", "hl_obj_fields", "hl_obj_get_field", "hl_obj_set_field", "hl_safe_cast",
            "hl_thread_id", "hl_throw", "hl_to_string", "hl_type_size", "hl_type_str", "hl_write_dyn",
            "hlt_abstract", "hlt_array", "hlt_bool", "hlt_bytes", "hlt_dyn", "hlt_f32", "hlt_f64", "hlt_i32"]

# files of ours that are refreshed on every install; everything else in mods/ belongs to the user
OURS = ("_lib/", "_examples/", "_docs/")
# ... except these, which are replaced when the copy in the game folder is still one we shipped
# (recognised by its first line), so an update brings the current diagnostics along
OURS_IF_UNTOUCHED = {"diag.lua": "-- diag.lua -- first-run diagnostics."}


# Examples of earlier releases, by SHA-256: a copy of one of these that the user put into mods/
# unchanged is brought up to date along with _examples/ (an edited copy is never touched).
OLD_EXAMPLES = {
    "gravity_gun.lua": ("a41c05c635736344d8b604d9e79a203ee8ab2af663c628e5c6b072ac2216f868",
                        "6b13e74c03a0e035a0ae75e45bbee89f4dd57efe8158a3a82e8abfa2b037c129"),
    "grapple.lua": ("0ee670d7c716609afd3f3c01e15861f5663a508ac8b20b6e03c3f3d50a45355f",),
    "moon.lua": ("333a50a2cd50f52b4a9af2b4df6fe9af143856265587ffb5d0d05816129cefb0",),
    "patterns.lua": ("48c50a50c3112488be744968041ba773a1762b863deb27e8bb789fdbfeed093d",),
    "physics_selftest.lua": ("66c9fe953811b6cc6c3f70f4daf49e2d4df8ab15e92bc8837acea7d0af03aeac",),
}


def _refresh_example_copies(src_mods, dst_mods):
    import hashlib
    done = []
    for name, old in OLD_EXAMPLES.items():
        mine = os.path.join(dst_mods, name)
        new = os.path.join(src_mods, "_examples", name)
        if not (os.path.isfile(mine) and os.path.isfile(new)):
            continue
        with open(mine, "rb") as fh:
            data = fh.read()
        if hashlib.sha256(data).hexdigest() in old or hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest() in old:
            shutil.copyfile(new, mine)
            done.append(name)
    return done


def _is_ours(path, rel):
    marker = OURS_IF_UNTOUCHED.get(rel)
    if not marker:
        return False
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.readline().startswith(marker)
    except OSError:
        return False


def looks_like_game_folder(folder):
    return any(os.path.exists(os.path.join(folder, f)) for f in ("libhl.dll", "fish.hdll"))


def pe_is_64bit(path):
    with open(path, "rb") as fh:
        d = fh.read(4096)
    if d[:2] != b"MZ":
        return None
    off = struct.unpack_from("<I", d, 0x3C)[0]
    if d[off:off + 4] != b"PE\0\0":
        return None
    return struct.unpack_from("<H", d, off + 4)[0] == 0x8664


def check_libhl(folder):
    """Returns (ok, message).  ok is None when there is no libhl.dll to check."""
    libhl = os.path.join(folder, "libhl.dll")
    if not os.path.exists(libhl):
        return None, "libhl.dll not found next to hlboot.dat, could not check compatibility"
    if pe_is_64bit(libhl) is False:
        return False, "this game is 32-bit; the bundled mosalua.hdll is 64-bit only"
    with open(libhl, "rb") as fh:
        lib = fh.read()
    missing = [s for s in REQUIRED if (s.encode() + b"\0") not in lib]
    if missing:
        return False, "the game's libhl.dll lacks functions the Lua runtime needs: " + ", ".join(missing)
    return True, "libhl.dll is compatible"


def install_runtime(game_dir, files_dir, hooks=None, info=None):
    """Copies mosalua.hdll and the mods folder template from files_dir into game_dir.
    info: what mosalua_patch.patch() returned; its lists of hookable functions and of native
    functions are written to mods/hookable.txt and mods/natives.txt (hooks alone, the older
    form, writes only the first).  Returns a list of human-readable notes."""
    if info is not None and hooks is None:
        hooks = info.get("hooks")
    notes = []
    dll = os.path.join(files_dir, "mosalua.hdll")
    if os.path.exists(dll):
        shutil.copyfile(dll, os.path.join(game_dir, "mosalua.hdll"))
        notes.append("mosalua.hdll copied")
    else:
        notes.append("WARNING: %s is missing" % dll)
    src_mods = os.path.join(files_dir, "mods")
    dst_mods = os.path.join(game_dir, "mods")
    first = not os.path.isdir(dst_mods)
    added = 0
    for root, _dirs, files in os.walk(src_mods):
        for f in files:
            src = os.path.join(root, f)
            rel = os.path.relpath(src, src_mods).replace(os.sep, "/")
            dst = os.path.join(dst_mods, *rel.split("/"))
            if os.path.exists(dst) and not rel.startswith(OURS) and not _is_ours(dst, rel):
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            added += 1
    notes.append("mods folder %s (%d files written): %s" % ("created" if first else "updated", added, dst_mods))
    for name in _refresh_example_copies(src_mods, dst_mods):
        notes.append("your copy of %s in mods was an unchanged older example: replaced with the current one" % name)
    if hooks is not None:
        import mosalua_patch
        mosalua_patch.write_hook_list(os.path.join(dst_mods, "hookable.txt"), {"hooks": hooks})
        notes.append("%d hookable functions listed in mods%shookable.txt" % (len(hooks), os.sep))
        if info is not None and info.get("natives"):
            mosalua_patch.write_native_list(os.path.join(dst_mods, "natives.txt"), info)
            notes.append("%d native functions listed in mods%snatives.txt" % (len(info["natives"]), os.sep))
    return notes
