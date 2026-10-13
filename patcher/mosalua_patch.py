#!/usr/bin/env python3
"""Add the Lua modding runtime to a HashLink game (hlboot.dat / *.hl).

    python mosalua_patch.py hlboot.dat hlboot_lua.dat

What it changes in the bytecode (and nothing else):

  * seven native functions imported from mosalua.hdll
  * a call to mosalua.boot() at the start of the game's main()
  * a short prologue at the start of every hookable function:
        if( mosalua.hooked(ID) ) return <run the Lua hook chain>;
    When no mod hooks the function this is one cheap native call.
  * the game's own native functions (Box2D, SDL, ...) are handed to the runtime so Lua can
    call them, and the ones of the physics library get a one-call wrapper function so
    they can be hooked like any other function (named lib@name, e.g. fish@world_step).

Works on a vanilla file and on one already modified by other patch tools.
Pure standard library; import `patch()` to use it from another tool.
"""
import fnmatch
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlbc
from hlbc import (HVOID, HUI8, HUI16, HI32, HI64, HF32, HF64, HBOOL, HBYTES, HDYN, HFUN, HOBJ, HARRAY,
                  HTYPE, HREF, HVIRTUAL, HDYNOBJ, HABSTRACT, HENUM, HNULL, HSTRUCT, enc_op)

LIB = "mosalua"
MARKER = "mosalua_patch_v2"
MAX_ARGS = 9   # HashLink's dynamic call limit: functions with more arguments are not hookable

# values of these kinds are already "dynamic" pointers; the others get boxed with ToDyn
DYNAMIC_KINDS = {HDYN, HFUN, HOBJ, HARRAY, HVIRTUAL, HDYNOBJ, HENUM, HNULL}
BOXED_KINDS = {HUI8, HUI16, HI32, HI64, HF32, HF64, HBOOL, HBYTES, HTYPE, HABSTRACT, HREF, HSTRUCT}

# Engine / standard library code is left alone by default: it is hot, and mods
# want to hook the game, not the renderer.  Everything else is hookable.
DEFAULT_EXCLUDE = [
    "hl.*", "haxe.*", "sys.*", "hxd.*", "h2d.*", "h3d.*", "hxsl.*", "format.*", "hscript.*", "sdl.*",
    "dx.*", "openal.*", "fmt.*", "uv.*", "ssl.*", "eval.*", "cpp.*", "js.*", "neko.*",
    "String.*", "Std.*", "Math.*", "Type.*", "Reflect.*", "Date.*", "EReg.*", "StringBuf.*", "StringTools.*",
    "Lambda.*", "Xml.*", "Array.*", "Sys.*", "Class.*", "Enum.*", "ArrayAccess.*", "IntIterator.*",
    "ValueType.*", "UInt.*", "List.*", "Map.*",
]
# ... except these, which mods need (frame tick, input, window events)
DEFAULT_INCLUDE = ["hxd.App.*", "hxd.Timer.update", "haxe.MainLoop.tick"]
# native libraries whose functions get a hookable wrapper (fish.hdll is Mosa Lina's Box2D binding).
# Every native of every library is callable from Lua either way.
DEFAULT_NATIVE_HOOKS = ["fish"]


class PatchError(Exception):
    pass


def _matches(name, patterns):
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def find_alltypes_global(bc, names):
    """Global holding the class registry: the first GetGlobal of Type.register()."""
    for findex, name in names.items():
        if name == "Type.register" and findex in bc.by_findex:
            for op, args in bc.by_findex[findex].decode_ops():
                if op == "GetGlobal":
                    return args[1]
    raise PatchError("could not locate the Haxe type registry (Type.register)")


NOT_MAIN = ["sys.thread.*", "haxe.EntryPoint.*", "haxe.MainLoop.*", "haxe.Timer.*", "Type.*"]


def find_main(bc, names, log=print):
    """The game's main(): the entry point function calls it once all classes are set up."""
    entry = bc.by_findex.get(bc.entrypoint)
    if entry is None:
        raise PatchError("entry point function not found")
    calls = [args[1] for op, args in entry.decode_ops() if op == "Call0" and args[1] in bc.by_findex]
    for fi in reversed(calls):
        if names.get(fi, "").endswith(".main"):
            return fi
    for fi in reversed(calls):      # no function literally called main: take the last plausible call
        ft = bc.types[bc.by_findex[fi].type]
        if not ft.args and bc.types[ft.ret].kind == HVOID and not _matches(names.get(fi, ""), NOT_MAIN):
            log("warning: no main() found by name, using %s" % names.get(fi, "function #%d" % fi))
            return fi
    raise PatchError("could not find the call to main() in the entry point")


def _signature_ok(bc, ft):
    """Can a function of this type go through the hook prologue?"""
    if ft.kind != HFUN or len(ft.args) > MAX_ARGS:
        return False
    arg_kinds = [bc.types[a].kind for a in ft.args]
    ret_kind = bc.types[ft.ret].kind
    if any(k not in DYNAMIC_KINDS and k not in BOXED_KINDS for k in arg_kinds):
        return False
    return ret_kind == HVOID or ret_kind in DYNAMIC_KINDS or ret_kind in BOXED_KINDS


def _call_op(dst, findex, args):
    n = len(args)
    if n <= 4:
        return enc_op("Call%d" % n, dst, findex, *args)
    return enc_op("CallN", dst, findex, list(args))


def patch(data, include=None, exclude=None, log=print, native_hooks=None):
    """Returns (patched_bytes, info).  info["hooks"] lists (name, signature) by id,
    info["natives"] the lib@name of every native function Lua can call."""
    bc = hlbc.Bytecode(data)
    if MARKER.encode() in bc.strings:
        raise PatchError("this file already contains the Lua runtime patch; start from the unpatched file")
    exclude = DEFAULT_EXCLUDE if exclude is None else exclude
    include = DEFAULT_INCLUDE if include is None else include
    native_hooks = DEFAULT_NATIVE_HOOKS if native_hooks is None else native_hooks

    names = bc.function_names()
    g_types = find_alltypes_global(bc, names)
    main_fi = find_main(bc, names, log)
    # anonymous functions (event handlers, callbacks, loop bodies) are named after their source line
    names = dict(names)
    names.update(bc.closure_names(names))

    t_void = bc.find_simple_type(HVOID)
    t_i32 = bc.find_simple_type(HI32)
    t_bool = bc.find_simple_type(HBOOL)
    t_dyn = bc.find_simple_type(HDYN)
    t_bytes = bc.find_simple_type(HBYTES)

    # The game's native functions.  Each one is given to the runtime as a closure so Lua can
    # call it; the ones of the selected libraries first get a wrapper function that takes over
    # their function index, which makes them hookable (and routes Lua's own calls through hooks).
    natives = []        # (lib@name, findex to take the closure of, type index)
    seen_native = {}
    nwrapped = 0
    for i, (lib, name, t, fi) in enumerate(list(bc.natives)):
        libname = bc.s(lib).lstrip("?")
        full = "%s@%s" % (libname, bc.s(name))
        k = seen_native.get(full, 0) + 1
        seen_native[full] = k
        if k > 1:
            full = "%s#%d" % (full, k)      # one native imported under several signatures
        ft = bc.types[t]
        if ft.kind != HFUN:
            continue
        if libname in native_hooks and _signature_ok(bc, ft) and full not in names.values():
            nargs = len(ft.args)

            def body(native_fi, ft=ft, nargs=nargs):
                ops = [_call_op(nargs, native_fi, list(range(nargs))), enc_op("Ret", nargs)]
                return list(ft.args) + [ft.ret], b"".join(ops), len(ops)
            names[bc.wrap_native(i, body)] = full
            nwrapped += 1
        natives.append((full, fi, t))       # fi is now the wrapper where there is one

    # natives must be declared with exactly the signature the hdll exports
    n_hooked = bc.add_native(LIB, "hooked", bc.find_fun_type([t_i32], t_bool))
    n_begin = bc.add_native(LIB, "begin", bc.find_fun_type([t_i32, t_dyn], t_void))
    n_arg = bc.add_native(LIB, "arg", bc.find_fun_type([t_dyn], t_void))
    n_invoke = bc.add_native(LIB, "invoke", bc.find_fun_type([t_i32], t_dyn))
    n_boot = bc.add_native(LIB, "boot", bc.find_fun_type([t_dyn, t_bytes], t_void))
    n_natives = bc.add_native(LIB, "natives", bc.find_fun_type([t_bytes], t_void))
    n_native = bc.add_native(LIB, "native", bc.find_fun_type([t_dyn], t_void))

    int_index = {}

    def int_const(v):
        if v not in int_index:
            int_index[v] = bc.add_int(v)
        return int_index[v]

    hooks = []          # (name, signature)
    skipped = {"unnamed": 0, "excluded": 0, "signature": 0, "duplicate": 0}
    seen_names = set()
    for f in bc.functions:
        name = names.get(f.findex)
        if name is None:
            skipped["unnamed"] += 1
            continue
        if f.findex == main_fi:
            continue
        if _matches(name, exclude) and not _matches(name, include):
            skipped["excluded"] += 1
            continue
        ft = bc.types[f.type]
        if not _signature_ok(bc, ft) or len(f.regs) < len(ft.args):
            skipped["signature"] += 1
            continue
        arg_kinds = [bc.types[a].kind for a in ft.args]
        ret_kind = bc.types[ft.ret].kind
        if name in seen_names:
            skipped["duplicate"] += 1
            continue
        seen_names.add(name)

        hook_id = len(hooks)
        hooks.append((name, bc.type_str(f.type)))
        base = len(f.regs)
        r_id, r_b, r_c, r_d, r_v, r_ret = base, base + 1, base + 2, base + 3, base + 4, base + 5
        new_regs = [t_i32, t_bool, f.type, t_dyn, t_void]
        slow = [enc_op("StaticClosure", r_c, f.findex),
                enc_op("UnsafeCast", r_d, r_c),
                enc_op("Call2", r_v, n_begin, r_id, r_d)]
        for i, k in enumerate(arg_kinds):
            slow.append(enc_op("UnsafeCast" if k in DYNAMIC_KINDS else "ToDyn", r_d, i))
            slow.append(enc_op("Call1", r_v, n_arg, r_d))
        slow.append(enc_op("Call1", r_d, n_invoke, r_id))
        if ret_kind == HVOID:
            slow.append(enc_op("Ret", r_v))
        elif ret_kind == HDYN:
            slow.append(enc_op("Ret", r_d))
        else:
            new_regs.append(ft.ret)
            slow.append(enc_op("SafeCast", r_ret, r_d))
            slow.append(enc_op("Ret", r_ret))
        head = [enc_op("Int", r_id, int_const(hook_id)),
                enc_op("Call1", r_b, n_hooked, r_id),
                enc_op("JFalse", r_b, len(slow))]
        ops = head + slow
        bc.prepend_ops(f, new_regs, b"".join(ops), len(ops))

    # a function that hands the natives to the runtime: registers 0 void, 1 dyn, 2 bytes,
    # then one register per distinct native signature
    reg_of = {}
    reg_types = [t_void, t_dyn, t_bytes]
    s_natives = bc.add_string("".join(n + "\n" for n, _, _ in natives))
    reg_ops = [enc_op("String", 2, s_natives), enc_op("Call1", 0, n_natives, 2)]
    for full, fi, t in natives:
        if t not in reg_of:
            reg_of[t] = len(reg_types)
            reg_types.append(t)
        reg_ops += [enc_op("StaticClosure", reg_of[t], fi),
                    enc_op("UnsafeCast", 1, reg_of[t]),
                    enc_op("Call1", 0, n_native, 1)]
    reg_ops.append(enc_op("Ret", 0))
    f_register = bc.add_function(bc.find_fun_type([], t_void), reg_types, b"".join(reg_ops), len(reg_ops))

    # boot call at the very start of main(): the class registry is complete by then
    table = "".join(n + "\n" for n, _ in hooks)
    s_table = bc.add_string(table)
    bc.add_string(MARKER)
    mf = bc.by_findex[main_fi]
    base = len(mf.regs)
    boot_ops = [enc_op("Call0", base + 3, f_register),
                enc_op("GetGlobal", base, g_types),
                enc_op("ToDyn" if bc.types[bc.globals[g_types]].kind not in DYNAMIC_KINDS else "UnsafeCast",
                       base + 1, base),
                enc_op("String", base + 2, s_table),
                enc_op("Call2", base + 3, n_boot, base + 1, base + 2)]
    bc.prepend_ops(mf, [bc.globals[g_types], t_dyn, t_bytes, t_void], b"".join(boot_ops), len(boot_ops))

    out = bc.serialise()
    hlbc.Bytecode(out)   # re-parse as a structural self check
    info = {"hooks": hooks, "skipped": skipped, "main": names.get(main_fi, "#%d" % main_fi),
            "functions": len(bc.functions), "version": bc.version,
            "natives": [(n, bc.type_str(t)) for n, _, t in natives], "native_hooks": nwrapped}
    nclosures = sum(1 for n, _ in hooks if ":" in n)
    log("bytecode v%d: %d functions, %d hookable (%d of them anonymous functions named File:line); "
        "left alone: %d engine/std, %d with unsupported signatures, %d without debug info"
        % (bc.version, len(bc.functions), len(hooks), nclosures, skipped["excluded"], skipped["signature"],
           skipped["unnamed"]))
    log("%d native functions callable from Lua, %d of them hookable (%s)"
        % (len(natives), nwrapped, ", ".join(native_hooks) or "none"))
    log("boot call inserted in %s; size %d -> %d bytes" % (info["main"], len(data), len(out)))
    return out, info


def write_hook_list(path, info):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# Functions mods can hook with mosa.hook / mosa.before / mosa.after / mosa.replace.\n")
        fh.write("# name <tab> signature (methods take the object itself as first argument)\n")
        fh.write("# Names like pkg.File:123 are anonymous functions, named after the source line they start on.\n")
        fh.write("# Names like lib@name are native functions (fish@... is the Box2D physics library).\n")
        for name, sig in sorted(info["hooks"]):
            fh.write("%s\t%s\n" % (name, sig))


def write_native_list(path, info):
    hookable = {n for n, _ in info["hooks"]}
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# Native functions of the game, callable with mosa.native(\"lib@name\")(...) (b2.raw.<name> for the fish library).\n")
        fh.write("# name <tab> signature <tab> 'hookable' when mosa.hook works on it\n")
        for name, sig in sorted(info["natives"]):
            fh.write("%s\t%s%s\n" % (name, sig, "\thookable" if name in hookable else ""))


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--include", action="append", default=[], help="extra pattern to make hookable (pkg.Class.*)")
    ap.add_argument("--exclude", action="append", default=[], help="extra pattern to leave untouched")
    ap.add_argument("--all", action="store_true", help="make engine and standard library functions hookable too")
    ap.add_argument("--list", metavar="FILE", help="write the list of hookable functions to FILE")
    ap.add_argument("--natives", metavar="LIBS", help="comma separated native libraries to make hookable "
                    "(default: %s; 'none' for none)" % ",".join(DEFAULT_NATIVE_HOOKS))
    ap.add_argument("--list-natives", metavar="FILE", help="write the list of native functions to FILE")
    a = ap.parse_args(argv)
    with open(a.input, "rb") as fh:
        data = fh.read()
    exclude = ([] if a.all else list(DEFAULT_EXCLUDE)) + a.exclude
    try:
        nh = None
        if a.natives:
            nh = [] if a.natives == "none" else [x.strip() for x in a.natives.split(",") if x.strip()]
        out, info = patch(data, include=DEFAULT_INCLUDE + a.include, exclude=exclude, native_hooks=nh)
    except (PatchError, ValueError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    with open(a.output, "wb") as fh:
        fh.write(out)
    if a.list:
        write_hook_list(a.list, info)
    if a.list_natives:
        write_native_list(a.list_natives, info)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
