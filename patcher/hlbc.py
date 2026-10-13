"""Minimal HashLink bytecode (.hl / hlboot.dat) reader/writer.

Pure standard library.  Everything that is not touched is kept as raw byte
slices, so an unmodified file re-serialises byte-for-byte identical.
Format reference: hashlink/src/code.c
"""
import struct

KINDS = ["void", "ui8", "ui16", "i32", "i64", "f32", "f64", "bool", "bytes", "dyn",
         "fun", "obj", "array", "type", "ref", "virtual", "dynobj", "abstract",
         "enum", "null", "method", "struct", "packed", "guid"]
(HVOID, HUI8, HUI16, HI32, HI64, HF32, HF64, HBOOL, HBYTES, HDYN, HFUN, HOBJ, HARRAY,
 HTYPE, HREF, HVIRTUAL, HDYNOBJ, HABSTRACT, HENUM, HNULL, HMETHOD, HSTRUCT, HPACKED,
 HGUID) = range(24)

# (name, nargs) in opcode order -- hashlink/src/opcodes.h
OPS = [("Mov", 2), ("Int", 2), ("Float", 2), ("Bool", 2), ("Bytes", 2), ("String", 2), ("Null", 1),
       ("Add", 3), ("Sub", 3), ("Mul", 3), ("SDiv", 3), ("UDiv", 3), ("SMod", 3), ("UMod", 3),
       ("Shl", 3), ("SShr", 3), ("UShr", 3), ("And", 3), ("Or", 3), ("Xor", 3),
       ("Neg", 2), ("Not", 2), ("Incr", 1), ("Decr", 1),
       ("Call0", 2), ("Call1", 3), ("Call2", 4), ("Call3", 5), ("Call4", 6),
       ("CallN", -1), ("CallMethod", -1), ("CallThis", -1), ("CallClosure", -1),
       ("StaticClosure", 2), ("InstanceClosure", 3), ("VirtualClosure", 3),
       ("GetGlobal", 2), ("SetGlobal", 2), ("Field", 3), ("SetField", 3), ("GetThis", 2), ("SetThis", 2),
       ("DynGet", 3), ("DynSet", 3),
       ("JTrue", 2), ("JFalse", 2), ("JNull", 2), ("JNotNull", 2), ("JSLt", 3), ("JSGte", 3), ("JSGt", 3),
       ("JSLte", 3), ("JULt", 3), ("JUGte", 3), ("JNotLt", 3), ("JNotGte", 3), ("JEq", 3), ("JNotEq", 3),
       ("JAlways", 1),
       ("ToDyn", 2), ("ToSFloat", 2), ("ToUFloat", 2), ("ToInt", 2), ("SafeCast", 2), ("UnsafeCast", 2),
       ("ToVirtual", 2),
       ("Label", 0), ("Ret", 1), ("Throw", 1), ("Rethrow", 1), ("Switch", -1), ("NullCheck", 1),
       ("Trap", 2), ("EndTrap", 1),
       ("GetI8", 3), ("GetI16", 3), ("GetMem", 3), ("GetArray", 3), ("SetI8", 3), ("SetI16", 3),
       ("SetMem", 3), ("SetArray", 3),
       ("New", 1), ("ArraySize", 2), ("Type", 2), ("GetType", 2), ("GetTID", 2),
       ("Ref", 2), ("Unref", 2), ("Setref", 2),
       ("MakeEnum", -1), ("EnumAlloc", 2), ("EnumIndex", 2), ("EnumField", 4), ("SetEnumField", 3),
       ("Assert", 0), ("RefData", 2), ("RefOffset", 3), ("Nop", 0), ("Prefetch", 3), ("Asm", 3)]
OP = {name: i for i, (name, _) in enumerate(OPS)}


def enc_index(v):
    if v < 0:
        v = -v
        if v < 0x2000:
            return bytes(((v >> 8) | 0xA0, v & 0xFF))
        if v >= 0x20000000:
            raise ValueError("index too big")
        return bytes(((v >> 24) | 0xE0, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))
    if v < 0x80:
        return bytes((v,))
    if v < 0x2000:
        return bytes(((v >> 8) | 0x80, v & 0xFF))
    if v >= 0x20000000:
        raise ValueError("index too big")
    return bytes(((v >> 24) | 0xC0, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))


def enc_op(name, *args):
    """Encode one opcode.  CallN & friends: (dst, fun, [args]); Switch not supported."""
    code = OP[name]
    n = OPS[code][1]
    out = bytearray((code,))
    if n == -1:
        dst, fun, extra = args
        out += enc_index(dst) + enc_index(fun) + bytes((len(extra),))
        for a in extra:
            out += enc_index(a)
    else:
        if len(args) != n:
            raise ValueError("%s takes %d args" % (name, n))
        for a in args:
            out += enc_index(a)
    return bytes(out)


class R:
    def __init__(self, data, pos=0):
        self.d = data
        self.p = pos

    def byte(self):
        b = self.d[self.p]
        self.p += 1
        return b

    def index(self):
        d = self.d
        b = d[self.p]
        if not b & 0x80:
            self.p += 1
            return b
        if not b & 0x40:
            v = d[self.p + 1] | ((b & 31) << 8)
            self.p += 2
            return -v if b & 0x20 else v
        v = ((b & 31) << 24) | (d[self.p + 1] << 16) | (d[self.p + 2] << 8) | d[self.p + 3]
        self.p += 4
        return -v if b & 0x20 else v

    def uindex(self):
        v = self.index()
        if v < 0:
            raise ValueError("negative index at %d" % self.p)
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.d, self.p)[0]
        self.p += 4
        return v

    def raw(self, n):
        v = self.d[self.p:self.p + n]
        if len(v) != n:
            raise ValueError("truncated file")
        self.p += n
        return v


class HType:
    __slots__ = ("kind", "raw", "args", "ret", "name", "super", "global_", "fields", "protos",
                 "bindings", "tparam", "constructs")

    def __init__(self, kind):
        self.kind = kind
        self.raw = None
        self.args = self.ret = self.name = self.super = self.global_ = None
        self.fields = self.protos = self.bindings = self.tparam = self.constructs = None


class HFunction:
    __slots__ = ("type", "findex", "regs", "nops", "ops_raw", "debug_raw", "assigns", "raw", "dirty")

    def decode_ops(self):
        return decode_ops(self.ops_raw, self.nops)


def decode_ops(raw, nops):
    r = R(raw)
    out = []
    for _ in range(nops):
        code = r.byte()
        name, n = OPS[code]
        if n >= 0:
            out.append((name, tuple(r.index() for _ in range(n))))
        elif name == "Switch":
            reg = r.uindex()
            cnt = r.uindex()
            offs = [r.uindex() for _ in range(cnt)]
            end = r.uindex()
            out.append((name, (reg, offs, end)))
        else:
            a = r.index()
            b = r.index()
            cnt = r.byte()
            out.append((name, (a, b, [r.index() for _ in range(cnt)])))
    if r.p != len(raw):
        raise ValueError("op decode size mismatch")
    return out


def _skip_ops(r, nops):
    ops = OPS
    d = r.d
    for _ in range(nops):
        code = d[r.p]
        r.p += 1
        n = ops[code][1]
        if n >= 0:
            for _ in range(n):
                b = d[r.p]
                r.p += 1 if not b & 0x80 else (2 if not b & 0x40 else 4)
        elif code == 70:  # Switch
            r.uindex()
            cnt = r.uindex()
            for _ in range(cnt + 1):
                r.uindex()
        else:
            r.index()
            r.index()
            cnt = r.byte()
            for _ in range(cnt):
                r.index()


def _read_debug(r, nops):
    """Returns (first_file, first_line).  Advances the reader past the debug block."""
    d = r.d
    curfile, curline = -1, 0
    first = None
    i = 0
    while i < nops:
        c = d[r.p]
        r.p += 1
        if c & 1:
            curfile = ((c >> 1) << 8) | d[r.p]
            r.p += 1
        elif c & 2:
            delta = c >> 6
            count = (c >> 2) & 15
            if first is None and count:
                first = (curfile, curline)
            i += count
            curline += delta
        elif c & 4:
            curline += c >> 3
            if first is None:
                first = (curfile, curline)
            i += 1
        else:
            curline = (c >> 3) | (d[r.p] << 5) | (d[r.p + 1] << 13)
            r.p += 2
            if first is None:
                first = (curfile, curline)
            i += 1
    if i != nops:
        raise ValueError("debug info overrun")
    return first or (0, 0)


class Bytecode:
    def __init__(self, data):
        self.data = data
        r = R(data)
        if r.raw(3) != b"HLB":
            raise ValueError("not a HashLink bytecode file (missing HLB header)")
        self.version = r.byte()
        if self.version < 2 or self.version > 5:
            raise ValueError("unsupported bytecode version %d" % self.version)
        self.flags = r.uindex()
        nints = r.uindex()
        nfloats = r.uindex()
        nstrings = r.uindex()
        nbytes = r.uindex() if self.version >= 5 else 0
        ntypes = r.uindex()
        nglobals = r.uindex()
        nnatives = r.uindex()
        nfunctions = r.uindex()
        nconstants = r.uindex() if self.version >= 4 else 0
        self.entrypoint = r.uindex()
        self.hasdebug = bool(self.flags & 1)
        self.ints = list(struct.unpack_from("<%di" % nints, data, r.p))
        r.p += 4 * nints
        self.floats_raw = r.raw(8 * nfloats)
        self.nfloats = nfloats
        self.strings = self._read_strings(r, nstrings)
        self.nbytes = nbytes
        if self.version >= 5:
            s = r.p
            size = r.i32()
            r.p += size
            for _ in range(nbytes):
                r.uindex()
            self.bytes_raw = data[s:r.p]
        else:
            self.bytes_raw = b""
        if self.hasdebug:
            s = r.p
            nfiles = r.uindex()
            self.debugfiles = self._read_strings(r, nfiles)
            self.debugfiles_raw = data[s:r.p]
        else:
            self.debugfiles = []
            self.debugfiles_raw = b""
        self.types = [self._read_type(r) for _ in range(ntypes)]
        self.globals = [r.uindex() for _ in range(nglobals)]
        self.natives = []
        for _ in range(nnatives):
            lib = r.index()
            name = r.index()
            t = r.index()
            fi = r.uindex()
            self.natives.append((lib, name, t, fi))
        self.functions = [self._read_function(r) for _ in range(nfunctions)]
        self.constants_raw = data[r.p:]
        self.nconstants = nconstants
        self._check_tail()
        self.by_findex = {f.findex: f for f in self.functions}

    # ---- reading ----
    @staticmethod
    def _read_strings(r, n):
        size = r.i32()
        blob = r.raw(size)
        out = []
        pos = 0
        for _ in range(n):
            ln = r.uindex()
            out.append(blob[pos:pos + ln])
            pos += ln + 1
        return out

    def _read_type(self, r):
        s = r.p
        t = HType(r.byte())
        k = t.kind
        if k in (HFUN, HMETHOD):
            n = r.byte()
            t.args = [r.index() for _ in range(n)]
            t.ret = r.index()
        elif k in (HOBJ, HSTRUCT):
            t.name = r.index()
            t.super = r.index()
            t.global_ = r.uindex()
            nf = r.uindex()
            np_ = r.uindex()
            nb = r.uindex()
            t.fields = [(r.index(), r.index()) for _ in range(nf)]
            t.protos = [(r.index(), r.uindex(), r.index()) for _ in range(np_)]
            t.bindings = [(r.uindex(), r.uindex()) for _ in range(nb)]
        elif k in (HREF, HNULL, HPACKED):
            t.tparam = r.index()
        elif k == HVIRTUAL:
            nf = r.uindex()
            t.fields = [(r.index(), r.index()) for _ in range(nf)]
        elif k == HABSTRACT:
            t.name = r.index()
        elif k == HENUM:
            t.name = r.index()
            t.global_ = r.uindex()
            nc = r.uindex()
            t.constructs = []
            for _ in range(nc):
                cname = r.index()
                npar = r.uindex()
                t.constructs.append((cname, [r.index() for _ in range(npar)]))
        elif k >= len(KINDS):
            raise ValueError("invalid type kind %d" % k)
        t.raw = r.d[s:r.p]
        return t

    def _read_function(self, r):
        f = HFunction()
        s = r.p
        f.type = r.index()
        f.findex = r.uindex()
        nregs = r.uindex()
        f.nops = r.uindex()
        f.regs = [r.index() for _ in range(nregs)]
        s2 = r.p
        _skip_ops(r, f.nops)
        f.ops_raw = r.d[s2:r.p]
        f.debug_raw = b""
        f.assigns = None
        if self.hasdebug:
            s3 = r.p
            _read_debug(r, f.nops)
            f.debug_raw = r.d[s3:r.p]
            if self.version >= 3:
                n = r.uindex()
                f.assigns = [(r.uindex(), r.index()) for _ in range(n)]
        f.raw = r.d[s:r.p]
        f.dirty = False
        return f

    def _check_tail(self):
        r = R(self.constants_raw)
        for _ in range(self.nconstants):
            r.uindex()
            n = r.uindex()
            for _ in range(n):
                r.uindex()
        if r.p != len(self.constants_raw):
            raise ValueError("trailing data after constants (%d bytes)" % (len(self.constants_raw) - r.p))

    # ---- helpers ----
    def s(self, i):
        return self.strings[i].decode("utf-8", "replace")

    def add_string(self, text):
        b = text.encode("utf-8") if isinstance(text, str) else text
        self.strings.append(b)
        return len(self.strings) - 1

    def find_string(self, text):
        b = text.encode("utf-8")
        try:
            return self.strings.index(b)
        except ValueError:
            return self.add_string(b)

    def add_int(self, v):
        self.ints.append(v)
        return len(self.ints) - 1

    def find_simple_type(self, kind):
        for i, t in enumerate(self.types):
            if t.kind == kind:
                return i
        t = HType(kind)
        t.raw = bytes((kind,))
        self.types.append(t)
        return len(self.types) - 1

    def find_fun_type(self, args, ret):
        for i, t in enumerate(self.types):
            if t.kind == HFUN and t.args == list(args) and t.ret == ret:
                return i
        t = HType(HFUN)
        t.args = list(args)
        t.ret = ret
        t.raw = bytes((HFUN, len(args))) + b"".join(enc_index(a) for a in args) + enc_index(ret)
        self.types.append(t)
        return len(self.types) - 1

    def add_native(self, lib, name, type_index):
        fi = len(self.functions) + len(self.natives)
        self.natives.append((self.find_string(lib), self.find_string(name), type_index, fi))
        return fi

    def next_findex(self):
        """Function indexes are one dense range shared by functions and natives."""
        return len(self.functions) + len(self.natives)

    def add_function(self, type_index, regs, ops_bytes, nops, findex=None):
        """Appends a new bytecode function; returns its findex."""
        f = HFunction()
        f.type = type_index
        f.findex = self.next_findex() if findex is None else findex
        f.regs = list(regs)
        f.nops = nops
        f.ops_raw = ops_bytes
        f.debug_raw = b""
        f.assigns = None
        if self.hasdebug:
            # file 0, then one absolute "line 0" entry per op
            f.debug_raw = bytes((1, 0)) + bytes(3) * nops
            if self.version >= 3:
                f.assigns = []
        f.raw = None
        f.dirty = True
        self.functions.append(f)
        self.by_findex[f.findex] = f
        return f.findex

    def wrap_native(self, i, ops_for):
        """Puts a bytecode function in front of native #i: the new function takes over the
        native's function index (so every existing call reaches it) and the native moves to
        a fresh index.  ops_for(native_findex) -> (regs, ops_bytes, nops) builds the body.
        Returns the wrapper's findex."""
        lib, name, t, old = self.natives[i]
        if old in self.by_findex:
            raise ValueError("native already wrapped")
        new = self.next_findex()
        self.natives[i] = (lib, name, t, new)
        regs, ops, nops = ops_for(new)
        return self.add_function(t, regs, ops, nops, findex=old)

    def type_str(self, i, depth=0):
        t = self.types[i]
        k = t.kind
        if k in (HFUN, HMETHOD):
            if depth > 2:
                return "fun"
            return "(%s)->%s" % (", ".join(self.type_str(a, depth + 1) for a in t.args),
                                 self.type_str(t.ret, depth + 1))
        if k == HENUM:
            # the captured-variables record of an anonymous function is compiled as a
            # one-constructor enum that reuses a placeholder name
            name = self.s(t.name)
            if not name or (len(t.constructs) == 1 and self.s(t.constructs[0][0]) == name and t.global_ == 0):
                return "captured-vars"
            return name
        if k in (HOBJ, HSTRUCT, HABSTRACT):
            return self.s(t.name)
        if k in (HREF, HNULL, HPACKED):
            return "%s<%s>" % (KINDS[k], self.type_str(t.tparam, depth + 1))
        return KINDS[k]

    def obj_field_name(self, tindex, fid):
        """Name of field #fid of an object type (indexes run through the super chain)."""
        chain = []
        t = self.types[tindex]
        while True:
            chain.append(t)
            if t.super is None or t.super < 0:
                break
            t = self.types[t.super]
        for t in reversed(chain):
            if fid < len(t.fields):
                return self.s(t.fields[fid][0])
            fid -= len(t.fields)
        return None

    def function_names(self):
        """findex -> 'pkg.Class.method' for every method / static function that has a name."""
        names = {}
        for ti, t in enumerate(self.types):
            if t.kind != HOBJ and t.kind != HSTRUCT:
                continue
            # the statics of pkg.Class live in a type named pkg.$Class
            cname = self.s(t.name)
            pkg, _, last = cname.rpartition(".")
            if last.startswith("$"):
                cname = (pkg + "." if pkg else "") + last[1:]
            for (pname, findex, _pindex) in t.protos:
                names.setdefault(findex, cname + "." + self.s(pname))
            for (fid, findex) in t.bindings:
                fname = self.obj_field_name(ti, fid)
                if fname is None:
                    continue
                if fname == "__constructor__":
                    fname = "new"
                names.setdefault(findex, cname + "." + fname)
        return names

    def debug_lines(self, f):
        """[(file index, line)] for every op of function f (empty without debug info)."""
        if not self.hasdebug:
            return []
        d = f.debug_raw
        out = []
        p = 0
        curfile, curline = -1, 0
        n = f.nops
        while len(out) < n:
            c = d[p]
            p += 1
            if c & 1:
                curfile = ((c >> 1) << 8) | d[p]
                p += 1
            elif c & 2:
                out.extend([(curfile, curline)] * ((c >> 2) & 15))
                curline += c >> 6
            elif c & 4:
                curline += c >> 3
                out.append((curfile, curline))
            else:
                curline = (c >> 3) | (d[p] << 5) | (d[p + 1] << 13)
                p += 2
                out.append((curfile, curline))
        return out

    def closure_names(self, taken):
        """findex -> 'pkg.File:line' for functions that have no method name (anonymous
        functions).  The file is the one most of the function's code comes from and the
        line its first line there; several on one line get #2, #3, ... in file order."""
        out = {}
        used = {}
        for f in sorted(self.functions, key=lambda f: f.findex):
            if f.findex in taken:
                continue
            lines = self.debug_lines(f)
            if not lines:
                continue
            count = {}
            for fl, _ln in lines:
                count[fl] = count.get(fl, 0) + 1
            fl = max(count, key=lambda k: (count[k], -k))
            if fl < 0 or fl >= len(self.debugfiles):
                continue
            line = min(ln for ff, ln in lines if ff == fl)
            path = self.debugfiles[fl].decode("utf-8", "replace").replace("\\", "/")
            if path.endswith(".hx"):
                path = path[:-3]
            for marker in ("/std/", "/src/"):
                if marker in path:
                    path = path.split(marker)[-1]
            if ":" in path or path.startswith("/"):
                path = "/".join(path.replace(":", "").split("/")[-2:])
            base = "%s:%d" % (path.strip("/").replace("/", "."), line)
            k = used.get(base, 0) + 1
            used[base] = k
            out[f.findex] = base if k == 1 else "%s#%d" % (base, k)
        return out

    # ---- writing ----
    @staticmethod
    def _write_strings(strings):
        blob = b"".join(s + b"\0" for s in strings)
        return struct.pack("<i", len(blob)) + blob + b"".join(enc_index(len(s)) for s in strings)

    def serialise(self):
        out = [b"HLB", bytes((self.version,)), enc_index(self.flags), enc_index(len(self.ints)),
               enc_index(self.nfloats), enc_index(len(self.strings))]
        if self.version >= 5:
            out.append(enc_index(self.nbytes))
        out += [enc_index(len(self.types)), enc_index(len(self.globals)), enc_index(len(self.natives)),
                enc_index(len(self.functions))]
        if self.version >= 4:
            out.append(enc_index(self.nconstants))
        out.append(enc_index(self.entrypoint))
        out.append(struct.pack("<%di" % len(self.ints), *self.ints))
        out.append(self.floats_raw)
        out.append(self._write_strings(self.strings))
        out.append(self.bytes_raw)
        out.append(self.debugfiles_raw)
        out += [t.raw for t in self.types]
        out += [enc_index(g) for g in self.globals]
        for (lib, name, t, fi) in self.natives:
            out.append(enc_index(lib) + enc_index(name) + enc_index(t) + enc_index(fi))
        for f in self.functions:
            out.append(f.raw if not f.dirty else self._write_function(f))
        out.append(self.constants_raw)
        return b"".join(out)

    def _write_function(self, f):
        out = [enc_index(f.type), enc_index(f.findex), enc_index(len(f.regs)), enc_index(f.nops)]
        out += [enc_index(x) for x in f.regs]
        out.append(f.ops_raw)
        if self.hasdebug:
            out.append(f.debug_raw)
            if self.version >= 3:
                out.append(enc_index(len(f.assigns)))
                for (name, pos) in f.assigns:
                    out.append(enc_index(name) + enc_index(pos))
        return b"".join(out)

    def prepend_ops(self, f, new_regs, ops_bytes, count):
        """Insert `count` encoded ops at the start of function f and append registers.

        Jumps, switches and traps in HashLink are relative, so shifting the body is safe.
        """
        first_file, first_line = _read_debug(R(f.debug_raw), f.nops) if self.hasdebug else (0, 0)
        f.regs = f.regs + list(new_regs)
        f.ops_raw = ops_bytes + f.ops_raw
        if self.hasdebug:
            if first_file < 0:
                first_file = 0
            dbg = bytearray((((first_file >> 8) << 1) | 1, first_file & 0xFF))
            line = min(first_line, 0x1FFFFF)
            for i in range(count):
                ln = line if i < count - 1 else 0     # last entry resets the line counter to 0
                dbg += bytes(((ln & 0x1F) << 3, (ln >> 5) & 0xFF, (ln >> 13) & 0xFF))
            # the original stream starts from (file=-1, line=0): it always sets its own file first
            f.debug_raw = bytes(dbg) + f.debug_raw
            if f.assigns is not None:
                f.assigns = [(n, p + count if p >= 0 else p) for (n, p) in f.assigns]
        f.nops += count
        f.dirty = True
