/*
 * mosalua.hdll -- Lua 5.4 scripting bridge for HashLink games.
 *
 * The patched bytecode calls seven natives:
 *
 *   natives(nameTable)          once, before boot: names of the game's native functions
 *   native(closure)             ... one call per name, in the same order
 *   boot(allTypes, hookTable)   once, right before the game's main()
 *   hooked(id) -> Bool          first op of every hookable function (fast path)
 *   begin(id, self_closure)     slow path: a Lua hook exists for this function
 *   arg(value)                  ... one call per argument
 *   invoke(id) -> Dynamic       ... run the Lua hook chain, returns the result
 *
 * Everything else (reading/writing fields, calling methods, creating objects)
 * goes through HashLink's own runtime reflection, so no per-game C is needed.
 *
 * Safety rules this file follows:
 *   - HashLink exceptions never unwind through Lua frames: every call into
 *     libhl that can throw runs inside hl_dyn_call_safe (see protect()).
 *   - Lua errors never unwind through HashLink frames: every entry from the
 *     game into Lua is a lua_pcall.
 *   - Lua only ever holds HashLink pointers through a GC-rooted handle table.
 */
#define HL_NAME(n) mosalua_##n
#include <hl.h>
#include <string.h>
#include <stdarg.h>
#include <limits.h>
#include <time.h>
#include <sys/stat.h>
#ifdef _WIN32
#	include <windows.h>
#else
#	include <dirent.h>
#	include <unistd.h>
#endif

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "mosa_lua.h"	/* generated: embedded Lua runtime (mosa_lua_src / mosa_lua_len) */

#define MOSALUA_VERSION "1.1.1"
#define HL_MAX_DYN_ARGS 9	/* HL_MAX_ARGS in hashlink/src/std/fun.c */
#define REF_MT "hl.ref"
#define EXC_MT "hl.exception"

/* ------------------------------------------------------------------ state */

typedef struct {
	int h;				/* index in the rooted handle table */
	int bypass;			/* >=0: calling this closure skips hooks of that id once ("orig") */
	int keep;			/* extra handle keeping a parent object alive (views into packed structs) */
	void *owner;		/* object the closure was read from (never dereferenced) */
	int selfarg;		/* struct method: the struct in `keep` is passed as the first argument */
} hlref;

typedef struct {
	int id;
	int base;			/* slot of the first argument in g_args */
	int nargs;
	bool orig_called;
	vclosure *orig;
} hook_frame;

static lua_State *g_L = NULL;
static bool g_booted = false;
static int g_main_thread = 0;
static char g_home[1024] = ".";
static FILE *g_log = NULL;

static void *g_types_map = NULL;		/* hl_bytes_map* : class name -> hl.BaseType */
static hl_type *g_tstring = NULL;

static unsigned char *g_hooked = NULL;	/* id -> has Lua hooks */
static char **g_hook_names = NULL;
static int g_nhooks = 0;
static int g_bypass = -1;

static varray *g_handles = NULL;		/* rooted: values referenced from Lua */
static int *g_free = NULL;
static int g_nfree = 0, g_handle_cap = 0;

static varray *g_natives = NULL;		/* rooted: closures of the game's native functions */
static char **g_native_names = NULL;	/* "lib@name" */
static int g_nnatives = 0, g_native_fill = 0;

static varray *g_args = NULL;			/* rooted: hook argument stack */
static int g_argtop = 0;
static hook_frame *g_frames = NULL;
static int g_nframes = 0, g_frame_cap = 0;

static int g_cache_ref = LUA_NOREF, g_dispatch_ref = LUA_NOREF, g_convert_ref = LUA_NOREF;
static int g_refmt_ref = LUA_NOREF, g_orig_ref = LUA_NOREF;

#define MAX_PENDING 4096
static int g_pending[MAX_PENDING];
static volatile int g_npending = 0;

static hl_type t_thunk, t_cb;
static hl_type_fun tf_thunk, tf_cb;
static hl_type *t_cb_args[2];
static vclosure c_thunk;

/* hl_bytes_map helpers and reflection primitives exported by libhl (std natives) */
HL_API vdynamic *hl_hbget( void *m, vbyte *key );
HL_API varray *hl_hbkeys( void *m );
HL_API vdynamic *hl_obj_get_field( vdynamic *obj, int hfield );
HL_API void hl_obj_set_field( vdynamic *obj, int hfield, vdynamic *v );
HL_API varray *hl_obj_fields( vdynamic *obj );
HL_API vdynamic *hl_call_method( vdynamic *c, varray *args );
HL_API vdynamic *hl_no_closure( vdynamic *c );
HL_API vdynamic *hl_get_closure_value( vdynamic *c );
HL_API vdynamic *hl_make_var_args( vclosure *c );
HL_API int hl_thread_id( void );

static bool g_f32_broken = false;	/* see dyn_call() */
static bool g_f32_cb_args = false;	/* see detect_f32_bug(): Single values on their way into a Lua callback */
static bool g_f32_cb_ret = false;	/* ... and on their way back */

/* -------------------------------------------------------------------- log */

static void log_line( const char *fmt, ... ) {
	va_list ap;
	char stamp[32];
	time_t now = time(NULL);
	struct tm *tm = localtime(&now);
	strftime(stamp, sizeof(stamp), "%H:%M:%S", tm);
	if( g_log ) {
		fprintf(g_log, "[%s] ", stamp);
		va_start(ap, fmt);
		vfprintf(g_log, fmt, ap);
		va_end(ap);
		fputc('\n', g_log);
		fflush(g_log);
	}
	if( getenv("MOSALUA_STDERR") ) {
		va_start(ap, fmt);
		vfprintf(stderr, fmt, ap);
		va_end(ap);
		fputc('\n', stderr);
		fflush(stderr);
	}
}

/* ------------------------------------------------------------ utf helpers */

static int ulen( const uchar *s ) {
	int n = 0;
	while( s[n] ) n++;
	return n;
}

/* UTF-16 (len code units) -> UTF-8 pushed as a Lua string */
static void push_utf16( lua_State *L, const uchar *s, int len ) {
	luaL_Buffer b;
	int i;
	luaL_buffinit(L, &b);
	for(i=0;i<len;i++) {
		unsigned int c = (unsigned short)s[i];
		if( c >= 0xD800 && c < 0xDC00 && i + 1 < len ) {
			unsigned int d = (unsigned short)s[i+1];
			if( d >= 0xDC00 && d < 0xE000 ) {
				c = 0x10000 + (((c - 0xD800) << 10) | (d - 0xDC00));
				i++;
			}
		}
		if( c < 0x80 )
			luaL_addchar(&b, (char)c);
		else if( c < 0x800 ) {
			luaL_addchar(&b, (char)(0xC0 | (c >> 6)));
			luaL_addchar(&b, (char)(0x80 | (c & 63)));
		} else if( c < 0x10000 ) {
			luaL_addchar(&b, (char)(0xE0 | (c >> 12)));
			luaL_addchar(&b, (char)(0x80 | ((c >> 6) & 63)));
			luaL_addchar(&b, (char)(0x80 | (c & 63)));
		} else {
			luaL_addchar(&b, (char)(0xF0 | (c >> 18)));
			luaL_addchar(&b, (char)(0x80 | ((c >> 12) & 63)));
			luaL_addchar(&b, (char)(0x80 | ((c >> 6) & 63)));
			luaL_addchar(&b, (char)(0x80 | (c & 63)));
		}
	}
	luaL_pushresult(&b);
}

static void push_ustr( lua_State *L, const uchar *s ) {
	if( !s ) lua_pushnil(L); else push_utf16(L, s, ulen(s));
}

/* UTF-8 -> GC allocated, zero terminated UTF-16.  *out_len = code units */
static uchar *utf8_to_utf16( const char *s, size_t len, int *out_len ) {
	uchar *out = (uchar*)hl_gc_alloc_noptr((int)((len + 1) * sizeof(uchar)));
	int n = 0;
	size_t i = 0;
	while( i < len ) {
		unsigned int c = (unsigned char)s[i++];
		if( c >= 0xF0 && i + 2 < len ) {
			c = ((c & 7) << 18) | ((s[i] & 63) << 12) | ((s[i+1] & 63) << 6) | (s[i+2] & 63);
			i += 3;
		} else if( c >= 0xE0 && i + 1 < len ) {
			c = ((c & 15) << 12) | ((s[i] & 63) << 6) | (s[i+1] & 63);
			i += 2;
		} else if( c >= 0xC0 && i < len ) {
			c = ((c & 31) << 6) | (s[i] & 63);
			i += 1;
		}
		if( c >= 0x10000 && c < 0x110000 ) {
			c -= 0x10000;
			out[n++] = (uchar)(0xD800 | (c >> 10));
			out[n++] = (uchar)(0xDC00 | (c & 0x3FF));
		} else
			out[n++] = (uchar)c;
	}
	out[n] = 0;
	if( out_len ) *out_len = n;
	return out;
}

static bool ustr_eq_utf8( const uchar *u, const char *s ) {
	while( *u && *s ) {
		if( (unsigned short)*u != (unsigned char)*s ) return false;
		u++; s++;
	}
	return !*u && !*s;
}

/* ---------------------------------------------------------- handle table */

static int handle_alloc( vdynamic *v ) {
	if( g_nfree == 0 ) {
		int ncap = g_handle_cap ? g_handle_cap * 2 : 1024, i;
		varray *na = hl_alloc_array(&hlt_dyn, ncap);
		if( g_handles )
			memcpy(hl_aptr(na,vdynamic*), hl_aptr(g_handles,vdynamic*), sizeof(void*) * g_handle_cap);
		g_handles = na;
		g_free = (int*)realloc(g_free, sizeof(int) * ncap);
		for(i=ncap-1;i>=g_handle_cap;i--)
			g_free[g_nfree++] = i;
		g_handle_cap = ncap;
	}
	{
		int h = g_free[--g_nfree];
		hl_aptr(g_handles,vdynamic*)[h] = v;
		return h;
	}
}

static void handle_free( int h ) {
	if( h < 0 || !g_handles ) return;
	hl_aptr(g_handles,vdynamic*)[h] = NULL;
	g_free[g_nfree++] = h;
}

#define HVAL(r) (hl_aptr(g_handles,vdynamic*)[(r)->h])

/* ------------------------------------------------- protected calls into HL */

typedef void (*pfun)( void *ud );
static pfun g_pfun = NULL;
static void *g_pud = NULL;

static vdynamic *protect_thunk( void ) {
	g_pfun(g_pud);
	return NULL;
}

/* Runs f(ud); returns true and sets *exc if a HashLink exception was thrown. */
static bool protect( pfun f, void *ud, vdynamic **exc ) {
	pfun of = g_pfun;
	void *oud = g_pud;
	bool is_exc = false;
	vdynamic *r;
	/* HashLink before 1.13 forgets to pop its trap when hl_dyn_call_safe returns
	   normally, leaving a dangling exception handler.  Restoring it ourselves is
	   correct on every version. */
	hl_thread_info *tinf = hl_get_thread();
	hl_trap_ctx *trap = tinf->trap_current;
	g_pfun = f;
	g_pud = ud;
	r = hl_dyn_call_safe(&c_thunk, NULL, 0, &is_exc);
	tinf->trap_current = trap;
	g_pfun = of;
	g_pud = oud;
	if( is_exc && exc ) *exc = r;
	return is_exc;
}

typedef struct {
	vdynamic *a, *b, *ret;
	int i;
	hl_type *t;
	void *p;
	const uchar *us;
} pargs;

static void p_get( void *u ) { pargs *p = (pargs*)u; p->ret = hl_obj_get_field(p->a, p->i); }
static void p_set( void *u ) { pargs *p = (pargs*)u; hl_obj_set_field(p->a, p->i, p->b); }
static void p_tostring( void *u ) { pargs *p = (pargs*)u; p->us = hl_to_string(p->a); }
static void p_alloc( void *u ) { pargs *p = (pargs*)u; p->ret = hl_alloc_obj(p->t); }
static void p_write( void *u ) { pargs *p = (pargs*)u; hl_write_dyn(p->p, p->t, p->b, false); }

/* ------------------------------------------------------------- exceptions */

static void push_ref( lua_State *L, vdynamic *v );
static void push_dyn( lua_State *L, vdynamic *v );
static vdynamic *dyn_f64( double v );

typedef struct { int h; } hlexc;

static int raise_hl( lua_State *L, vdynamic *exc ) {
	hlexc *e = (hlexc*)lua_newuserdatauv(L, sizeof(hlexc), 0);
	e->h = -1;
	luaL_setmetatable(L, EXC_MT);
	e->h = handle_alloc(exc);
	return lua_error(L);
}

static hlexc *to_exc( lua_State *L, int idx ) {
	return (hlexc*)luaL_testudata(L, idx, EXC_MT);
}

static void push_tostring( lua_State *L, vdynamic *v ) {
	pargs p;
	vdynamic *exc = NULL;
	memset(&p, 0, sizeof(p));
	p.a = v;
	if( v == NULL ) { lua_pushliteral(L, "null"); return; }
	if( protect(p_tostring, &p, &exc) || !p.us )
		lua_pushliteral(L, "<toString failed>");
	else
		push_ustr(L, p.us);
}

static void push_exc_message( lua_State *L, hlexc *e ) {
	lua_pushliteral(L, "game exception: ");
	push_tostring(L, e->h >= 0 ? hl_aptr(g_handles,vdynamic*)[e->h] : NULL);
	lua_concat(L, 2);
}

static int exc_tostring( lua_State *L ) {
	push_exc_message(L, (hlexc*)luaL_checkudata(L, 1, EXC_MT));
	return 1;
}

static int exc_gc( lua_State *L ) {
	hlexc *e = (hlexc*)luaL_checkudata(L, 1, EXC_MT);
	handle_free(e->h);
	e->h = -1;
	return 0;
}

static int exc_index( lua_State *L ) {
	hlexc *e = (hlexc*)luaL_checkudata(L, 1, EXC_MT);
	const char *k = lua_tostring(L, 2);
	if( k && strcmp(k, "value") == 0 && e->h >= 0 ) {
		push_dyn(L, hl_aptr(g_handles,vdynamic*)[e->h]);
		return 1;
	}
	if( k && strcmp(k, "message") == 0 ) {
		push_tostring(L, e->h >= 0 ? hl_aptr(g_handles,vdynamic*)[e->h] : NULL);
		return 1;
	}
	return 0;
}

/* error handler: keeps game exceptions intact, adds a traceback to Lua errors */
static int msgh( lua_State *L ) {
	if( to_exc(L, 1) ) return 1;
	{
		const char *msg = lua_tostring(L, 1);
		if( msg == NULL ) {
			if( luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING )
				msg = lua_tostring(L, -1);
			else
				msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
		}
		luaL_traceback(L, L, msg, 1);
	}
	return 1;
}

/* ------------------------------------------------- structs and references */

/*
 * @:struct values have no type header, so HashLink's own reflection cannot hand
 * them out as Dynamic (hl_make_dyn returns the raw pointer).  The convention the
 * JIT uses is a box: a vdynamic whose type is the struct type and whose value
 * points at the data.  Everything struct-typed is boxed that way before Lua sees it.
 */
static vdynamic *box_ptr( hl_type *t, void *p ) {
	vdynamic *d = hl_alloc_dynamic(t);
	d->t = t;
	d->v.ptr = p;
	return d;
}

/* reads the value stored at addr; never returns an unboxed struct */
static vdynamic *read_value( void *addr, hl_type *t ) {
	if( t->kind == HSTRUCT ) {
		void *p = *(void**)addr;
		return p ? box_ptr(t, p) : NULL;
	}
	if( t->kind == HPACKED )
		return box_ptr(t->tparam, addr);
	return hl_make_dyn(addr, t);
}

/* declared field of an object/struct type: its type and byte offset */
static bool find_field( hl_type *t, int hash, hl_type **ft, int *off ) {
	while( t ) {
		hl_type_obj *o = t->obj;
		int i;
		for(i=0;i<o->nfields;i++)
			if( o->fields[i].hashed_name == hash ) {
				hl_runtime_obj *rt = hl_get_obj_rt(t);
				*ft = o->fields[i].t;
				*off = rt->fields_indexes[rt->nfields - o->nfields + i];
				return true;
			}
		t = o->super;
	}
	return false;
}

static bool is_struct_kind( hl_type *t ) {
	return t->kind == HSTRUCT || t->kind == HPACKED;
}

/*
 * Method of an object/struct type, straight from the type's prototype list.
 * HashLink's own lookup cannot be used for structs: it reads a method table that
 * only exists once the type has been instantiated by HashLink itself, and it binds
 * the boxed value where the method expects the bare struct.
 */
static vclosure *find_method( hl_type *t, int hash ) {
	while( t ) {
		hl_type_obj *o = t->obj;
		int i;
		for(i=0;i<o->nproto;i++)
			if( o->proto[i].hashed_name == hash && o->m ) {
				int fi = o->proto[i].findex;
				vclosure *c = (vclosure*)hl_gc_alloc_gen(o->m->functions_types[fi], sizeof(vclosure), MEM_KIND_NOPTR);
				c->t = o->m->functions_types[fi];
				c->fun = o->m->functions_ptrs[fi];
				c->hasValue = 0;
#				ifdef HL_64
				c->stackCount = 0;
#				endif
				c->value = NULL;
				return c;
			}
		t = o->super;
	}
	return NULL;
}

/* ---------------------------------------------------------- HL -> Lua */

static void push_hlstring( lua_State *L, vstring *s ) {
	if( !s->bytes ) lua_pushliteral(L, ""); else push_utf16(L, s->bytes, s->length);
}

static hlref *new_ref( lua_State *L, vdynamic *v ) {
	hlref *r = (hlref*)lua_newuserdatauv(L, sizeof(hlref), 0);
	r->h = -1;
	r->bypass = -1;
	r->keep = -1;
	r->owner = NULL;
	r->selfarg = 0;
	lua_rawgeti(L, LUA_REGISTRYINDEX, g_refmt_ref);
	lua_setmetatable(L, -2);
	r->h = handle_alloc(v);
	return r;
}

static void push_ref( lua_State *L, vdynamic *v ) {
	if( v->t->kind == HFUN ) {	/* closures are not cached: each carries its own owner */
		new_ref(L, v);
		return;
	}
	lua_rawgeti(L, LUA_REGISTRYINDEX, g_cache_ref);
	if( lua_rawgetp(L, -1, v) == LUA_TUSERDATA ) {
		lua_remove(L, -2);
		return;
	}
	lua_pop(L, 1);
	new_ref(L, v);
	lua_pushvalue(L, -1);
	lua_rawsetp(L, -3, v);
	lua_remove(L, -2);
}

static void push_dyn( lua_State *L, vdynamic *v ) {
	hl_type *t;
	if( v == NULL ) { lua_pushnil(L); return; }
	t = v->t;
	if( t->kind == HVIRTUAL && ((vvirtual*)v)->value ) {
		/* an object seen through an anonymous-structure type: hand out the object itself,
		   so the same instance is the same value in Lua whatever the game's static type was */
		v = ((vvirtual*)v)->value;
		t = v->t;
	}
	switch( t->kind ) {
	case HUI8: lua_pushinteger(L, v->v.ui8); return;
	case HUI16: lua_pushinteger(L, v->v.ui16); return;
	case HI32: lua_pushinteger(L, v->v.i); return;
	case HI64: lua_pushinteger(L, (lua_Integer)v->v.i64); return;
	case HF32: lua_pushnumber(L, v->v.f); return;
	case HF64: lua_pushnumber(L, v->v.d); return;
	case HBOOL: lua_pushboolean(L, v->v.b); return;
	case HOBJ:
		if( t == g_tstring ) { push_hlstring(L, (vstring*)v); return; }
		break;
	default:
		break;
	}
	push_ref(L, v);
}

static hlref *check_ref( lua_State *L, int idx ) {
	hlref *r = (hlref*)luaL_checkudata(L, idx, REF_MT);
	if( r->h < 0 ) luaL_error(L, "stale game object reference");
	return r;
}

static vdynamic *test_refval( lua_State *L, int idx ) {
	hlref *r = (hlref*)luaL_testudata(L, idx, REF_MT);
	return r && r->h >= 0 ? HVAL(r) : NULL;
}

/* ---------------------------------------------------------- Lua -> HL */

static vdynamic *make_string( const char *s, size_t len ) {
	vstring *str = (vstring*)hl_alloc_obj(g_tstring);
	int n = 0;
	str->bytes = utf8_to_utf16(s, len, &n);
	str->length = n;
	return (vdynamic*)str;
}

static vdynamic *dyn_i32( int v ) { vdynamic *d = hl_alloc_dynamic(&hlt_i32); d->t = &hlt_i32; d->v.i = v; return d; }
static vdynamic *dyn_f64( double v ) { vdynamic *d = hl_alloc_dynamic(&hlt_f64); d->t = &hlt_f64; d->v.d = v; return d; }

static vdynamic *make_closure( lua_State *L, int idx, hl_type *hint );
static vdynamic *to_dyn( lua_State *L, int idx, hl_type *hint );

/* fills the struct at `base` from a Lua table: fields by name, or by position ({x, y}) */
static void fill_struct( lua_State *L, int idx, hl_type *st, char *base, int depth ) {
	hl_type *chain[16];
	int nchain = 0, c, pos = 0;
	hl_type *t = st;
	if( depth > 8 ) luaL_error(L, "struct table nested too deeply");
	while( t && nchain < 16 ) { chain[nchain++] = t; t = t->obj->super; }
	idx = lua_absindex(L, idx);
	luaL_checkstack(L, 6, "struct table");
	for(c=nchain-1;c>=0;c--) {
		hl_type_obj *o = chain[c]->obj;
		int i;
		for(i=0;i<o->nfields;i++) {
			hl_type *ft = o->fields[i].t;
			int off;
			hl_type *tmp;
			pos++;
			push_ustr(L, o->fields[i].name);
			lua_gettable(L, idx);
			if( lua_isnil(L, -1) ) {
				lua_pop(L, 1);
				lua_rawgeti(L, idx, pos);
			}
			if( lua_isnil(L, -1) ) { lua_pop(L, 1); continue; }
			if( !find_field(st, o->fields[i].hashed_name, &tmp, &off) ) { lua_pop(L, 1); continue; }
			if( is_struct_kind(ft) ) {
				hl_type *inner = ft->kind == HPACKED ? ft->tparam : ft;
				vdynamic *val = test_refval(L, -1);
				if( lua_istable(L, -1) && ft->kind == HPACKED )
					fill_struct(L, -1, inner, base + off, depth + 1);
				else if( lua_istable(L, -1) ) {
					vdynamic *sub = to_dyn(L, -1, ft);
					*(void**)(base + off) = sub ? sub->v.ptr : NULL;
				} else if( val && val->t->kind == HSTRUCT && hl_safe_cast(val->t, inner) ) {
					if( ft->kind == HSTRUCT ) *(void**)(base + off) = val->v.ptr;
					else memcpy(base + off, val->v.ptr, hl_get_obj_rt(inner)->size);
				} else
					luaL_error(L, "struct field needs a table or a struct of the same type");
			} else {
				pargs p;
				vdynamic *exc = NULL;
				memset(&p, 0, sizeof(p));
				p.p = base + off;
				p.t = ft;
				p.b = to_dyn(L, -1, ft);
				if( protect(p_write, &p, &exc) ) raise_hl(L, exc);
			}
			lua_pop(L, 1);
		}
	}
}

static vdynamic *to_dyn( lua_State *L, int idx, hl_type *hint ) {
	int hk = hint ? (int)hint->kind : (int)HDYN;
	if( hk == HNULL || hk == HREF ) {
		hint = hint->tparam;
		hk = hint->kind;
	}
	switch( lua_type(L, idx) ) {
	case LUA_TNIL:
	case LUA_TNONE:
		return NULL;
	case LUA_TBOOLEAN:
		return hl_alloc_dynbool(lua_toboolean(L, idx) != 0);
	case LUA_TNUMBER:
		if( lua_isinteger(L, idx) ) {
			lua_Integer n = lua_tointeger(L, idx);
			if( hk == HF64 || hk == HF32 ) return dyn_f64((double)n);
			if( hk == HBOOL ) return hl_alloc_dynbool(n != 0);
			if( n >= INT_MIN && n <= INT_MAX ) return dyn_i32((int)n);
			return dyn_f64((double)n);
		} else {
			lua_Number x = lua_tonumber(L, idx);
			if( hk == HI32 || hk == HUI8 || hk == HUI16 || hk == HI64 ) return dyn_i32((int)x);
			if( hk == HBOOL ) return hl_alloc_dynbool(x != 0);
			return dyn_f64(x);
		}
	case LUA_TSTRING:
		{
			size_t len;
			const char *s = lua_tolstring(L, idx, &len);
			if( hk == HBYTES ) {
				vdynamic *d = hl_alloc_dynamic(&hlt_bytes);
				d->t = &hlt_bytes;
				d->v.ptr = utf8_to_utf16(s, len, NULL);
				return d;
			}
			if( hk == HENUM ) {
				hl_type_enum *e = hint->tenum;
				int i;
				for(i=0;i<e->nconstructs;i++)
					if( e->constructs[i].nparams == 0 && ustr_eq_utf8(e->constructs[i].name, s) )
						return (vdynamic*)hl_alloc_enum(hint, i);
				luaL_error(L, "'%s' is not a parameterless constructor of this enum", s);
			}
			return make_string(s, len);
		}
	case LUA_TUSERDATA:
		{
			hlref *r = (hlref*)luaL_testudata(L, idx, REF_MT);
			hlexc *e;
			if( r ) {
				if( r->h < 0 ) luaL_error(L, "stale game object reference");
				return HVAL(r);
			}
			e = to_exc(L, idx);
			if( e && e->h >= 0 ) return hl_aptr(g_handles,vdynamic*)[e->h];
			luaL_error(L, "cannot pass this userdata to the game");
			return NULL;
		}
	case LUA_TFUNCTION:
		return make_closure(L, idx, hint);
	case LUA_TTABLE:
		{
			vdynamic *v;
			if( hk == HARRAY ) {
				int n = (int)lua_rawlen(L, idx), i;
				varray *a = hl_alloc_array(&hlt_dyn, n);
				idx = lua_absindex(L, idx);
				for(i=0;i<n;i++) {
					lua_rawgeti(L, idx, i + 1);
					hl_aptr(a,vdynamic*)[i] = to_dyn(L, -1, NULL);
					lua_pop(L, 1);
				}
				return (vdynamic*)a;
			}
			if( hk == HSTRUCT ) {
				/* {x = 1, y = 2} or {1, 2} where the game expects a struct */
				pargs p;
				vdynamic *exc = NULL, *box;
				memset(&p, 0, sizeof(p));
				p.t = hint;
				if( protect(p_alloc, &p, &exc) ) raise_hl(L, exc);
				box = box_ptr(hint, p.ret);
				fill_struct(L, idx, hint, (char*)p.ret, 0);
				return box;
			}
			if( g_convert_ref == LUA_NOREF )
				luaL_error(L, "cannot convert a table (runtime not ready)");
			idx = lua_absindex(L, idx);
			lua_rawgeti(L, LUA_REGISTRYINDEX, g_convert_ref);
			lua_pushvalue(L, idx);
			lua_pushinteger(L, hk);
			lua_call(L, 2, 1);
			if( lua_type(L, -1) == LUA_TTABLE )
				luaL_error(L, "table conversion returned a table");
			v = to_dyn(L, -1, hint);
			lua_pop(L, 1);
			return v;
		}
	default:
		luaL_error(L, "cannot pass a %s to the game", luaL_typename(L, idx));
		return NULL;
	}
}

/* ------------------------------------------- Lua functions as HL closures */

typedef struct {
	void (*finalize)( void * );
	int ref;
	/* HashLink 1.x mishandles Single values in its closure wrappers as well (see dyn_call).
	   When we know the signature the callback stands in for, we undo that here. */
	unsigned int f32_args;
	bool f32_ret;
	hl_type *sig;		/* signature the callback was created for, when known */
} cb_ctx;

static void cb_finalize( void *p ) {
	cb_ctx *c = (cb_ctx*)p;
	if( c->ref >= 0 && g_npending < MAX_PENDING )
		g_pending[g_npending++] = c->ref;
	c->ref = -1;
}

static void drain_pending( void ) {
	while( g_npending > 0 ) {
		int ref = g_pending[--g_npending];
		luaL_unref(g_L, LUA_REGISTRYINDEX, ref);
	}
}

typedef struct { cb_ctx *ctx; varray *args; vdynamic *ret; } cb_call;

static int cb_body( lua_State *L ) {
	cb_call *c = (cb_call*)lua_touserdata(L, 1);
	int n = c->args ? c->args->size : 0, i;
	luaL_checkstack(L, n + 4, "too many callback arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, c->ctx->ref);
	for(i=0;i<n;i++) {
		vdynamic *v = hl_aptr(c->args,vdynamic*)[i];
		hl_type *sig = c->ctx->sig;
		if( i < 32 && (c->ctx->f32_args & (1u << i)) && v && v->t->kind == HF64 )
			lua_pushnumber(L, v->v.f);	/* a float that arrived in the low half of a "double" */
		else if( v && sig && i < sig->fun->nargs && sig->fun->args[i]->kind == HSTRUCT )
			push_dyn(L, box_ptr(sig->fun->args[i], v));	/* the wrapper passes structs unboxed */
		else
			push_dyn(L, v);
	}
	lua_call(L, n, 1);
	if( c->ctx->f32_ret && lua_type(L, -1) == LUA_TNUMBER ) {
		vdynamic *d = hl_alloc_dynamic(&hlt_f64);
		d->t = &hlt_f64;
		d->v.i64 = 0;
		d->v.f = (float)lua_tonumber(L, -1);
		c->ret = d;
	} else
		c->ret = to_dyn(L, -1, NULL);
	return 0;
}

static vdynamic *cb_entry( cb_ctx *ctx, varray *args ) {
	lua_State *L = g_L;
	cb_call c;
	int top, st;
	vdynamic *exc = NULL;
	if( !L || ctx->ref < 0 || hl_thread_id() != g_main_thread ) return NULL;
	drain_pending();
	c.ctx = ctx; c.args = args; c.ret = NULL;
	top = lua_gettop(L);
	if( !lua_checkstack(L, 8) ) return NULL;
	lua_pushcfunction(L, msgh);
	lua_pushcfunction(L, cb_body);
	lua_pushlightuserdata(L, &c);
	st = lua_pcall(L, 1, 0, top + 1);
	if( st != LUA_OK ) {
		hlexc *e = to_exc(L, -1);
		if( e && e->h >= 0 )
			exc = hl_aptr(g_handles,vdynamic*)[e->h];
		else
			log_line("ERROR in Lua callback: %s", lua_tostring(L, -1));
		lua_settop(L, top);
		if( exc ) hl_throw(exc);
		return NULL;
	}
	lua_settop(L, top);
	return c.ret;
}

static vdynamic *make_closure( lua_State *L, int idx, hl_type *hint ) {
	cb_ctx *ctx = (cb_ctx*)hl_gc_alloc_finalizer(sizeof(cb_ctx));
	vclosure *base;
	ctx->finalize = cb_finalize;
	ctx->ref = -1;
	ctx->f32_args = 0;
	ctx->f32_ret = false;
	ctx->sig = hint && hint->kind == HFUN ? hint : NULL;
	if( hint && hint->kind == HFUN ) {
		int i;
		if( g_f32_cb_args )
			for(i=0;i<hint->fun->nargs && i<32;i++)
				if( hint->fun->args[i]->kind == HF32 ) ctx->f32_args |= 1u << i;
		ctx->f32_ret = g_f32_cb_ret && hint->fun->ret->kind == HF32;
	}
	lua_pushvalue(L, idx);
	ctx->ref = luaL_ref(L, LUA_REGISTRYINDEX);
	base = hl_alloc_closure_ptr(&t_cb, cb_entry, ctx);
	return hl_make_var_args(base);
}

/* ----------------------------------------------------------- calling HL */

/*
 * hl_dyn_call_safe with two repairs for HashLink 1.x:
 *
 * - before 1.13 it leaves a dangling exception trap when the call returns normally;
 * - its C-to-JIT trampoline passes 32-bit float arguments as doubles, so a function
 *   declared with Single parameters receives garbage.  We describe those parameters
 *   as doubles instead and hand over a "double" whose low 4 bytes are the float:
 *   the trampoline copies doubles bit for bit, and the callee reads the low 4 bytes.
 */
static vdynamic *dyn_call( vclosure *c, vdynamic **args, int nargs, bool *is_exc ) {
	hl_thread_info *tinf = hl_get_thread();
	hl_trap_ctx *trap = tinf->trap_current;
	hl_type *fargs[HL_MAX_DYN_ARGS + 2];
	hl_type_fun ffull, fclos;
	hl_type tfull, tclos;
	vclosure fc;
	vdynamic *ret;
	hl_type_fun *tf = c->t->fun;
	if( g_f32_broken && tf->nargs >= 0 && c->hasValue != 2 ) {
		hl_type *full = c->hasValue ? tf->parent : c->t;
		hl_type_fun *ff = full->fun;
		int off = c->hasValue ? 1 : 0, i;
		bool has = false;
		if( ff->nargs <= HL_MAX_DYN_ARGS + 1 )
			for(i=0;i<ff->nargs;i++)
				if( ff->args[i]->kind == HF32 ) has = true;
		if( has ) {
			for(i=0;i<ff->nargs;i++)
				fargs[i] = ff->args[i]->kind == HF32 ? &hlt_f64 : ff->args[i];
			for(i=0;i<nargs && i+off<ff->nargs;i++)
				if( ff->args[i+off]->kind == HF32 ) {
					vdynamic *d = hl_alloc_dynamic(&hlt_f64);
					float f = args[i] ? (float)hl_dyn_castd(&args[i], &hlt_dyn) : 0.f;
					d->t = &hlt_f64;
					d->v.i64 = 0;
					d->v.f = f;
					args[i] = d;
				}
			ffull = *ff;
			ffull.args = fargs;
			tfull = *full;
			tfull.fun = &ffull;
			fc = *c;
			if( c->hasValue ) {
				fclos = *tf;
				fclos.args = fargs + 1;
				fclos.parent = &tfull;
				tclos = *c->t;
				tclos.fun = &fclos;
				fc.t = &tclos;
			} else
				fc.t = &tfull;
			c = &fc;
		}
	}
	ret = hl_dyn_call_safe(c, args, nargs, is_exc);
	tinf->trap_current = trap;
	return ret;
}

static float f32_echo( float f ) {
	return f;
}

/*
 * The other direction: game code calling a Lua function through a typed closure.  HashLink
 * wraps our variable-argument closure (hl_make_fun_wrapper); its wrapper boxes a Single
 * argument as a "double" holding the float in its low 4 bytes, and hands a returned double to
 * a caller that reads a float.  Still so in 1.16, where the C-to-JIT direction is fixed, hence
 * a test of its own: we call such a wrapper the way compiled code does and look at both ends.
 */
static int g_probe_arg;		/* 0 not seen, 1 a proper value, 2 float in the low half, 3 neither */
static bool g_probe_low;

static vdynamic *f32_probe( void *unused, varray *args ) {
	vdynamic *a = args && args->size == 1 ? hl_aptr(args,vdynamic*)[0] : NULL;
	vdynamic *r;
	if( !a ) g_probe_arg = 3;
	else if( a->t->kind == HF32 ) g_probe_arg = a->v.f == 1.5f ? 1 : 3;
	else if( a->t->kind == HF64 ) g_probe_arg = a->v.d == 1.5 ? 1 : (a->v.f == 1.5f ? 2 : 3);
	else g_probe_arg = 3;
	r = hl_alloc_dynamic(&hlt_f64);
	r->t = &hlt_f64;
	if( g_probe_low ) { r->v.i64 = 0; r->v.f = 2.5f; } else r->v.d = 2.5;
	return r;
}

static void detect_f32_callbacks( hl_type *t ) {
	vclosure *base, *w;
	float r;
	g_f32_cb_args = g_f32_cb_ret = g_f32_broken;	/* what held up to 1.14, if we cannot test */
	base = hl_alloc_closure_ptr(&t_cb, f32_probe, &t_cb);	/* same shape as a Lua callback (make_closure) */
	w = hl_make_fun_wrapper((vclosure*)hl_make_var_args(base), t);
	if( !w || !w->fun ) return;
	g_probe_arg = 0; g_probe_low = false;
	r = ((float(*)(void*,float))w->fun)(w->value, 1.5f);
	if( g_probe_arg == 0 ) return;
	if( g_probe_arg == 3 ) {
		log_line("WARNING: Lua functions used as callbacks receive wrong Single (32-bit float) arguments on this HashLink");
		g_f32_cb_args = false;
	} else
		g_f32_cb_args = g_probe_arg == 2;
	if( r == 2.5f ) { g_f32_cb_ret = false; return; }
	g_probe_low = true;
	r = ((float(*)(void*,float))w->fun)(w->value, 1.5f);
	if( r == 2.5f ) { g_f32_cb_ret = true; return; }
	log_line("WARNING: Lua functions used as callbacks cannot return Single (32-bit float) values on this HashLink");
	g_f32_cb_ret = false;
}

static void detect_f32_bug( void ) {
	static hl_type t;
	static hl_type_fun tf;
	static hl_type *targs[1];
	vclosure cl;
	vdynamic *arg, *ret;
	bool is_exc = false;
	int pass;
	targs[0] = &hlt_f32;
	tf.args = targs;
	tf.nargs = 1;
	tf.ret = &hlt_f32;
	t.kind = HFUN;
	t.fun = &tf;
	memset(&cl, 0, sizeof(cl));
	cl.t = &t;
	cl.fun = (void*)f32_echo;
	for(pass=0;pass<2;pass++) {
		arg = dyn_f64(1.5);
		ret = dyn_call(&cl, &arg, 1, &is_exc);
		if( !is_exc && ret && ret->v.f == 1.5f )
			break;
		if( pass ) {
			log_line("WARNING: functions with Single (32-bit float) parameters cannot be called from Lua on this HashLink");
			g_f32_broken = false;
			break;
		}
		g_f32_broken = true;
	}
	detect_f32_callbacks(&t);
	if( g_f32_broken || g_f32_cb_args || g_f32_cb_ret )
		log_line("note: this HashLink mishandles Single values (calls %s, callback arguments %s, callback results %s); workaround active",
			g_f32_broken ? "yes" : "no", g_f32_cb_args ? "yes" : "no", g_f32_cb_ret ? "yes" : "no");
}

/* the object holding the statics of pkg.Class has a type named pkg.$Class */
static bool is_class_object( vdynamic *v ) {
	const uchar *n, *last;
	if( !v || v->t->kind != HOBJ || !v->t->obj->name ) return false;
	last = n = v->t->obj->name;
	while( *n ) {
		if( *n == '.' ) last = n + 1;
		n++;
	}
	return *last == '$';
}

/* Converts one call argument.  A by-reference parameter (hl.Ref<T>, which is also how optional
   Int/Float/Bool arguments with defaults are passed) gets a fresh cell holding the value. */
static vdynamic *conv_arg( lua_State *L, int idx, hl_type *at ) {
	if( at && at->kind == HREF && !lua_isnoneornil(L, idx) ) {
		vdynamic *given = test_refval(L, idx), *exc = NULL;
		void **cell;
		pargs p;
		if( given && given->t->kind == HREF ) return given;
		cell = (void**)hl_gc_alloc_raw(16);
		cell[0] = cell[1] = NULL;
		memset(&p, 0, sizeof(p));
		p.p = cell;
		p.t = at->tparam;
		p.b = to_dyn(L, idx, at->tparam);
		if( protect(p_write, &p, &exc) ) raise_hl(L, exc);
		return box_ptr(at, cell);
	}
	return to_dyn(L, idx, at);
}

/* Calls closure c with the Lua values at [first, first+n).  Pushes the result. */
static int do_call( lua_State *L, vclosure *c, int first, int n, hlref *self ) {
	vdynamic *args[HL_MAX_DYN_ARGS + 1];
	vdynamic *ret, *exc;
	hl_type **targs;
	bool is_exc = false;
	int need, total, i, off = 0;
	int bypass = self ? self->bypass : -1;
	if( c->hasValue == 2 ) {
		/* a wrapper made by a cast through Dynamic: call what it wraps, like Reflect.callMethod does */
		vdynamic *cval = hl_get_closure_value((vdynamic*)c);
		c = (vclosure*)hl_no_closure((vdynamic*)c);
		if( cval ) {
			args[0] = cval;
			off = 1;
		}
	}
	need = c->t->fun->nargs;		/* -1 for variable argument closures (Lua callbacks) */
	targs = c->t->fun->args;
	total = n + off;
	if( need > total ) total = need;	/* omitted trailing arguments are passed as null */
	if( total > HL_MAX_DYN_ARGS )
		return luaL_error(L, "too many arguments (%d): the game can be called with at most %d", total, HL_MAX_DYN_ARGS);
	for(i=0;i<n;i++)
		args[i + off] = conv_arg(L, first + i, (i + off < need) ? targs[i + off] : NULL);
	for(i=n+off;i<total;i++)
		args[i] = NULL;
	if( bypass >= 0 ) {
		g_bypass = bypass;
		for(i=g_nframes-1;i>=0;i--)
			if( g_frames[i].id == bypass ) {
				g_frames[i].orig_called = true;
				break;
			}
	}
	ret = dyn_call(c, args, total, &is_exc);
	if( bypass >= 0 && g_bypass == bypass ) g_bypass = -1;
	if( is_exc ) {
		exc = ret;
		return raise_hl(L, exc);
	}
	push_dyn(L, ret);
	return 1;
}

static vdynamic *get_field( lua_State *L, vdynamic *o, int hash ) {
	pargs p;
	vdynamic *exc = NULL;
	memset(&p, 0, sizeof(p));
	p.a = o;
	p.i = hash;
	if( protect(p_get, &p, &exc) ) raise_hl(L, exc);
	return p.ret;
}

static hl_type *class_type( lua_State *L, vdynamic *cls ) {
	vdynamic *t;
	if( cls == NULL ) return NULL;
	if( cls->t->kind == HTYPE ) return (hl_type*)cls->v.ptr;
	if( cls->t->kind != HOBJ ) return NULL;
	t = get_field(L, cls, hl_hash_utf8("__type__"));
	if( t == NULL || t->t->kind != HTYPE ) return NULL;
	return (hl_type*)t->v.ptr;
}

static vdynamic *resolve_class( lua_State *L, int idx ) {
	if( lua_type(L, idx) == LUA_TSTRING ) {
		size_t len;
		const char *s = lua_tolstring(L, idx, &len);
		if( !g_types_map ) return NULL;
		return hl_hbget(g_types_map, (vbyte*)utf8_to_utf16(s, len, NULL));
	}
	return test_refval(L, idx);
}

/* construct(cls, args at [first, first+n)) */
static int do_new( lua_State *L, vdynamic *cls, int first, int n ) {
	hl_type *t = class_type(L, cls);
	vdynamic *ctor, *exc = NULL, *obj;
	pargs p;
	if( t == NULL || (t->kind != HOBJ && t->kind != HSTRUCT) ) return luaL_error(L, "not a class");
	memset(&p, 0, sizeof(p));
	p.t = t;
	if( protect(p_alloc, &p, &exc) ) return raise_hl(L, exc);
	obj = t->kind == HSTRUCT ? box_ptr(t, p.ret) : p.ret;
	ctor = get_field(L, cls, hl_hash_utf8("__constructor__"));
	if( ctor && ctor->t->kind == HFUN ) {
		vclosure *f = (vclosure*)hl_no_closure(ctor);
		vdynamic *args[HL_MAX_DYN_ARGS + 1], *ret;
		bool is_exc = false;
		int need = f->t->fun->nargs, total = n + 1, i;
		if( need > total ) total = need;
		if( total > HL_MAX_DYN_ARGS ) return luaL_error(L, "constructor takes too many arguments");
		args[0] = obj;
		for(i=0;i<n;i++)
			args[i+1] = conv_arg(L, first + i, i + 1 < need ? f->t->fun->args[i+1] : NULL);
		for(i=n+1;i<total;i++)
			args[i] = NULL;
		ret = dyn_call(f, args, total, &is_exc);
		if( is_exc ) return raise_hl(L, ret);
	}
	push_dyn(L, obj);
	return 1;
}

static bool call_named( lua_State *L, vdynamic *o, const char *name, int first, int n ) {
	vdynamic *m = get_field(L, o, hl_hash_utf8(name));
	if( m == NULL || m->t->kind != HFUN ) return false;
	do_call(L, (vclosure*)m, first, n, NULL);
	return true;
}

/* ----------------------------------------------------------- metatable */

static int ref_gc( lua_State *L ) {
	hlref *r = (hlref*)luaL_checkudata(L, 1, REF_MT);
	handle_free(r->h);
	handle_free(r->keep);
	r->h = r->keep = -1;
	return 0;
}

static void push_enum_param( lua_State *L, venum *e, int i ) {
	hl_enum_construct *c = e->t->tenum->constructs + e->index;
	push_dyn(L, read_value((char*)e + c->offsets[i], c->params[i]));
}

static int index_int( lua_State *L, vdynamic *v, lua_Integer i ) {
	switch( v->t->kind ) {
	case HARRAY:
		{
			varray *a = (varray*)v;
			if( i < 0 || i >= a->size ) return 0;
			push_dyn(L, read_value(hl_aptr(a,char) + i * hl_type_size(a->at), a->at));
			return 1;
		}
	case HENUM:
		{
			venum *e = (venum*)v;
			hl_enum_construct *c = e->t->tenum->constructs + e->index;
			if( i < 0 || i >= c->nparams ) return 0;
			push_enum_param(L, e, (int)i);
			return 1;
		}
	case HOBJ:
	case HVIRTUAL:
		lua_pushinteger(L, i);
		if( call_named(L, v, "getDyn", lua_gettop(L), 1) ) return 1;
		return 0;
	default:
		return 0;
	}
}

static int ref_index( lua_State *L ) {
	hlref *r = check_ref(L, 1);
	vdynamic *v = HVAL(r), *res;
	const char *k;
	if( lua_type(L, 2) == LUA_TNUMBER ) {
		if( !lua_isinteger(L, 2) ) return 0;
		return index_int(L, v, lua_tointeger(L, 2));
	}
	if( lua_type(L, 2) != LUA_TSTRING ) return 0;
	k = lua_tostring(L, 2);
	switch( v->t->kind ) {
	case HOBJ:
	case HSTRUCT:
		{
			/* struct-typed fields: reflection would return them unboxed */
			hl_type *ft;
			int off;
			if( find_field(v->t, hl_hash_utf8(k), &ft, &off) && is_struct_kind(ft) ) {
				char *base = v->t->kind == HSTRUCT ? (char*)v->v.ptr : (char*)v;
				if( ft->kind == HSTRUCT ) {
					void *sp = *(void**)(base + off);
					if( !sp ) return 0;
					new_ref(L, box_ptr(ft, sp));
				} else {
					hlref *nr = new_ref(L, box_ptr(ft->tparam, base + off));
					nr->keep = handle_alloc(v);
				}
				return 1;
			}
			if( v->t->kind == HSTRUCT ) {
				vclosure *m = find_method(v->t, hl_hash_utf8(k));
				if( m ) {
					hlref *nr = new_ref(L, (vdynamic*)m);
					nr->owner = v;
					nr->keep = handle_alloc(v);
					nr->selfarg = 1;
					return 1;
				}
			}
		}
		/* fallthrough */
	case HVIRTUAL:
	case HDYNOBJ:
		if( v->t->kind == HVIRTUAL ) {
			hl_type_virtual *vt = v->t->virt;
			int i, h = hl_hash_utf8(k);
			for(i=0;i<vt->nfields;i++)
				if( vt->fields[i].hashed_name == h && is_struct_kind(vt->fields[i].t) ) return 0;
		}
		res = get_field(L, v, hl_hash_utf8(k));
		if( res && res->t->kind == HFUN ) {
			hlref *nr = new_ref(L, res);
			nr->owner = v;
			return 1;
		}
		push_dyn(L, res);
		return 1;
	case HENUM:
		{
			venum *e = (venum*)v;
			hl_enum_construct *c = e->t->tenum->constructs + e->index;
			if( strcmp(k, "index") == 0 ) { lua_pushinteger(L, e->index); return 1; }
			if( strcmp(k, "name") == 0 ) { push_ustr(L, c->name); return 1; }
			if( strcmp(k, "nparams") == 0 ) { lua_pushinteger(L, c->nparams); return 1; }
			if( strcmp(k, "args") == 0 ) {
				int i;
				lua_createtable(L, c->nparams, 0);
				for(i=0;i<c->nparams;i++) {
					push_enum_param(L, e, i);
					lua_rawseti(L, -2, i + 1);
				}
				return 1;
			}
			return 0;
		}
	case HARRAY:
		if( strcmp(k, "length") == 0 ) { lua_pushinteger(L, ((varray*)v)->size); return 1; }
		return 0;
	case HFUN:
		if( strcmp(k, "nargs") == 0 ) { lua_pushinteger(L, ((vclosure*)v)->t->fun->nargs); return 1; }
		return 0;
	case HREF:
		if( strcmp(k, "value") == 0 && v->v.ptr ) { push_dyn(L, read_value(v->v.ptr, v->t->tparam)); return 1; }
		return 0;
	default:
		return 0;
	}
}

static int ref_newindex( lua_State *L ) {
	hlref *r = check_ref(L, 1);
	vdynamic *v = HVAL(r), *exc = NULL;
	pargs p;
	memset(&p, 0, sizeof(p));
	if( lua_type(L, 2) == LUA_TNUMBER ) {
		lua_Integer i = luaL_checkinteger(L, 2);
		if( v->t->kind == HARRAY ) {
			varray *a = (varray*)v;
			if( i < 0 || i >= a->size ) return luaL_error(L, "array index %d out of bounds (size %d)", (int)i, a->size);
			p.p = hl_aptr(a,char) + i * hl_type_size(a->at);
			p.t = a->at;
			p.b = to_dyn(L, 3, a->at);
			if( protect(p_write, &p, &exc) ) return raise_hl(L, exc);
			return 0;
		}
		if( v->t->kind == HOBJ || v->t->kind == HVIRTUAL ) {
			lua_settop(L, 3);
			if( call_named(L, v, "setDyn", 2, 2) ) return 0;
		}
		return luaL_error(L, "this value cannot be indexed with a number");
	}
	{
		size_t len;
		const char *k = luaL_checklstring(L, 2, &len);
		hl_type *hint = NULL;
		switch( v->t->kind ) {
		case HOBJ:
		case HVIRTUAL:
		case HDYNOBJ:
		case HSTRUCT:
			break;
		case HREF:
			if( strcmp(k, "value") == 0 && v->v.ptr ) {
				p.p = v->v.ptr;
				p.t = v->t->tparam;
				p.b = to_dyn(L, 3, v->t->tparam);
				if( protect(p_write, &p, &exc) ) return raise_hl(L, exc);
				return 0;
			}
			/* fallthrough */
		default:
			return luaL_error(L, "cannot set field '%s' on this value", k);
		}
		if( v->t->kind == HOBJ || v->t->kind == HSTRUCT ) {
			hl_type *ft;
			int off;
			if( find_field(v->t, hl_hash_utf8(k), &ft, &off) && is_struct_kind(ft) ) {
				char *base = v->t->kind == HSTRUCT ? (char*)v->v.ptr : (char*)v;
				hl_type *st = ft->kind == HPACKED ? ft->tparam : ft;
				vdynamic *val = test_refval(L, 3);
				if( lua_isnil(L, 3) && ft->kind == HSTRUCT ) {
					*(void**)(base + off) = NULL;
					return 0;
				}
				if( lua_istable(L, 3) ) {
					/* { x = 1, y = 2 } or { 1, 2 }: copied into the struct that is there (other code
					   may hold the same struct); a new one is made only where the field is null */
					void *cur = ft->kind == HPACKED ? (void*)(base + off) : *(void**)(base + off);
					if( cur )
						fill_struct(L, 3, st, (char*)cur, 0);
					else {
						vdynamic *nv = to_dyn(L, 3, ft);
						*(void**)(base + off) = nv ? nv->v.ptr : NULL;
					}
					return 0;
				}
				if( !val || val->t->kind != HSTRUCT || !hl_safe_cast(val->t, st) )
					return luaL_error(L, "field '%s' needs a struct value of the same type", k);
				if( ft->kind == HSTRUCT )
					*(void**)(base + off) = val->v.ptr;
				else
					memcpy(base + off, val->v.ptr, hl_get_obj_rt(st)->size);
				return 0;
			}
		}
		p.a = v;
		/* register the name so Reflect.fields() can resolve it on dynamic objects */
		p.i = hl_hash_gen(utf8_to_utf16(k, len, NULL), true);
		if( v->t->kind == HOBJ || v->t->kind == HSTRUCT ) {
			/* find the declared field type so strings/tables/functions convert properly */
			hl_type *t = v->t;
			while( t && !hint ) {
				int i;
				for(i=0;i<t->obj->nfields;i++)
					if( t->obj->fields[i].hashed_name == p.i ) { hint = t->obj->fields[i].t; break; }
				t = t->obj->super;
			}
		}
		p.b = to_dyn(L, 3, hint);
		if( protect(p_set, &p, &exc) ) return raise_hl(L, exc);
	}
	return 0;
}

static int ref_call( lua_State *L ) {
	hlref *r = check_ref(L, 1);
	vdynamic *v = HVAL(r);
	int n = lua_gettop(L) - 1;
	if( v->t->kind == HFUN ) {
		vclosure *c = (vclosure*)v;
		int need = c->t->fun->nargs;
		int first = 2;
		if( r->selfarg ) {
			/* struct method: `this` is an ordinary first argument.  s:method(a) already
			   passes it; s.method(a) does not, so it is put in front. */
			vdynamic *a0 = n > 0 ? test_refval(L, 2) : NULL, *self = (vdynamic*)r->owner;
			if( !(a0 && a0->t->kind == HSTRUCT && a0->v.ptr == self->v.ptr && n >= need) ) {
				if( r->keep < 0 ) return luaL_error(L, "stale struct method");
				push_ref(L, hl_aptr(g_handles,vdynamic*)[r->keep]);
				lua_insert(L, 2);
				n++;
			}
			return do_call(L, c, 2, n, r);
		}
		/* obj:method(a) passes obj again as first argument: drop it.  For a bound method
		   that is always what a leading `obj` means; for anything else read from an object
		   (static functions, function-typed fields) only when the argument count says so. */
		if( n > 0 && r->owner && test_refval(L, 2) == (vdynamic*)r->owner
			&& ((c->hasValue == 1 && c->value == r->owner) || (need >= 0 && n == need + 1)) ) {
			first = 3;
			n--;
		}
		return do_call(L, c, first, n, r);
	}
	if( is_class_object(v) )
		return do_new(L, v, 2, n);
	return luaL_error(L, "attempt to call a game value that is not a function");
}

static int ref_tostring( lua_State *L ) {
	hlref *r = (hlref*)luaL_checkudata(L, 1, REF_MT);
	vdynamic *v;
	if( r->h < 0 ) { lua_pushliteral(L, "<stale>"); return 1; }
	v = HVAL(r);
	if( v->t->kind == HFUN ) {
		lua_pushliteral(L, "function: ");
		push_ustr(L, hl_type_str(v->t));
		lua_concat(L, 2);
		return 1;
	}
	if( v->t->kind == HSTRUCT || v->t->kind == HREF || v->t->kind == HBYTES || v->t->kind == HABSTRACT || v->t->kind == HTYPE ) {
		lua_pushliteral(L, "<");
		push_ustr(L, v->t->kind == HSTRUCT ? v->t->obj->name : hl_type_str(v->t));
		if( v->t->kind == HABSTRACT ) lua_pushfstring(L, " %p>", v->v.ptr); else lua_pushliteral(L, ">");
		lua_concat(L, 3);
		return 1;
	}
	push_tostring(L, v);
	return 1;
}

static int ref_len( lua_State *L ) {
	hlref *r = check_ref(L, 1);
	vdynamic *v = HVAL(r), *len;
	if( v->t->kind == HARRAY ) { lua_pushinteger(L, ((varray*)v)->size); return 1; }
	if( v->t->kind == HOBJ || v->t->kind == HVIRTUAL || v->t->kind == HDYNOBJ ) {
		len = get_field(L, v, hl_hash_utf8("length"));
		if( len && len->t->kind == HI32 ) { lua_pushinteger(L, len->v.i); return 1; }
		if( v->t->kind == HOBJ && call_named(L, v, "get_length", 0, 0) ) return 1;
	}
	lua_pushinteger(L, 0);
	return 1;
}

static int ref_eq( lua_State *L ) {
	vdynamic *a = test_refval(L, 1), *b = test_refval(L, 2);
	if( a == b ) { lua_pushboolean(L, a != NULL); return 1; }
	if( a && b && a->t->kind == b->t->kind && (a->t->kind == HSTRUCT || a->t->kind == HREF
		|| a->t->kind == HABSTRACT || a->t->kind == HBYTES || a->t->kind == HTYPE) ) {
		lua_pushboolean(L, a->v.ptr == b->v.ptr);	/* two boxes around the same struct / native pointer */
		return 1;
	}
	if( a && b && a->t->kind == HFUN && b->t->kind == HFUN ) {
		vclosure *ca = (vclosure*)a, *cb = (vclosure*)b;
		lua_pushboolean(L, ca->fun == cb->fun && ca->hasValue == cb->hasValue && (!ca->hasValue || ca->value == cb->value));
		return 1;
	}
	lua_pushboolean(L, 0);
	return 1;
}

/* ------------------------------------------------------------ hl.* API */

static int l_class( lua_State *L ) {
	vdynamic *c;
	luaL_checktype(L, 1, LUA_TSTRING);
	c = resolve_class(L, 1);
	if( c ) push_ref(L, c); else lua_pushnil(L);
	return 1;
}

static int l_classes( lua_State *L ) {
	varray *keys;
	int i;
	if( !g_types_map ) { lua_newtable(L); return 1; }
	keys = hl_hbkeys(g_types_map);
	lua_createtable(L, keys->size, 0);
	for(i=0;i<keys->size;i++) {
		push_ustr(L, hl_aptr(keys,uchar*)[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

static int l_new( lua_State *L ) {
	vdynamic *cls = resolve_class(L, 1);
	if( !cls ) return luaL_error(L, "unknown class '%s'", lua_tostring(L, 1) ? lua_tostring(L, 1) : "?");
	return do_new(L, cls, 2, lua_gettop(L) - 1);
}

static const char *KIND_NAMES[] = { "void", "ui8", "ui16", "i32", "i64", "f32", "f64", "bool", "bytes", "dyn", "fun",
	"obj", "array", "type", "ref", "virtual", "dynobj", "abstract", "enum", "null", "method", "struct", "packed", "guid" };

static const char *kind_name( int k ) {
	return k >= 0 && k < (int)(sizeof(KIND_NAMES)/sizeof(*KIND_NAMES)) ? KIND_NAMES[k] : "?";
}

/* hl.typeof(v) -> kind, type name   (nil for plain Lua values) */
static int l_typeof( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	if( !v ) return 0;
	lua_pushstring(L, kind_name(v->t->kind));
	switch( v->t->kind ) {
	case HOBJ: case HSTRUCT: push_ustr(L, v->t->obj->name); break;
	case HENUM: push_ustr(L, v->t->tenum->name); break;
	default: push_ustr(L, hl_type_str(v->t)); break;
	}
	return 2;
}

static int l_classof( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	void **g;
	if( !v ) return 0;
	if( v->t->kind == HOBJ || v->t->kind == HSTRUCT ) g = v->t->obj->global_value;
	else if( v->t->kind == HENUM ) g = v->t->tenum->global_value;
	else return 0;
	if( !g || !*g ) return 0;
	push_ref(L, (vdynamic*)*g);
	return 1;
}

static int l_super( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	hl_type *t = v && (v->t->kind == HOBJ || v->t->kind == HSTRUCT) && !is_class_object(v) ? v->t : class_type(L, v);
	if( !t || (t->kind != HOBJ && t->kind != HSTRUCT) || !t->obj->super ) return 0;
	push_ustr(L, t->obj->super->obj->name);
	return 1;
}

static int l_is( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	vdynamic *cls = resolve_class(L, 2);
	hl_type *t = class_type(L, cls);
	if( !v || !t ) { lua_pushboolean(L, 0); return 1; }
	lua_pushboolean(L, hl_safe_cast(v->t, t));
	return 1;
}

/* hl.fields(obj_or_class [, statics]) -> { {name=, type=, method=bool}, ... } */
static int l_fields( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	hl_type *t;
	int n = 0, i;
	if( !v ) return luaL_error(L, "expected a game object");
	lua_newtable(L);
	if( v->t->kind == HDYNOBJ || v->t->kind == HVIRTUAL ) {
		varray *a = hl_obj_fields(v);
		if( a ) for(i=0;i<a->size;i++) {
			lua_createtable(L, 0, 2);
			push_ustr(L, hl_aptr(a,uchar*)[i]);
			lua_setfield(L, -2, "name");
			lua_rawseti(L, -2, ++n);
		}
		return 1;
	}
	if( v->t->kind != HOBJ && v->t->kind != HSTRUCT ) return 1;
	t = v->t;
	if( is_class_object(v) && lua_toboolean(L, 2) == 0 ) {
		/* a class: describe its instances */
		hl_type *it = class_type(L, v);
		if( it && (it->kind == HOBJ || it->kind == HSTRUCT) ) t = it;
	}
	while( t ) {
		hl_type_obj *o = t->obj;
		for(i=0;i<o->nfields;i++) {
			if( !o->fields[i].name || !o->fields[i].name[0] ) continue;
			lua_createtable(L, 0, 3);
			push_ustr(L, o->fields[i].name); lua_setfield(L, -2, "name");
			push_ustr(L, hl_type_str(o->fields[i].t)); lua_setfield(L, -2, "type");
			push_ustr(L, o->name); lua_setfield(L, -2, "class");
			lua_rawseti(L, -2, ++n);
		}
		for(i=0;i<o->nproto;i++) {
			lua_createtable(L, 0, 3);
			push_ustr(L, o->proto[i].name); lua_setfield(L, -2, "name");
			lua_pushboolean(L, 1); lua_setfield(L, -2, "method");
			push_ustr(L, o->name); lua_setfield(L, -2, "class");
			lua_rawseti(L, -2, ++n);
		}
		t = o->super;
	}
	return 1;
}

static int l_tostring( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	if( v ) push_tostring(L, v); else luaL_tolstring(L, 1, NULL);
	return 1;
}

static int l_enum( lua_State *L ) {
	vdynamic *cls = resolve_class(L, 1);
	hl_type *t = class_type(L, cls);
	const char *name = luaL_checkstring(L, 2);
	hl_type_enum *e;
	int i, j, n = lua_gettop(L) - 2;
	if( !t || t->kind != HENUM ) return luaL_error(L, "not an enum");
	e = t->tenum;
	for(i=0;i<e->nconstructs;i++) {
		hl_enum_construct *c = e->constructs + i;
		venum *v;
		if( !ustr_eq_utf8(c->name, name) ) continue;
		if( n != c->nparams ) return luaL_error(L, "enum constructor %s takes %d parameter(s)", name, c->nparams);
		v = hl_alloc_enum(t, i);
		for(j=0;j<c->nparams;j++) {
			pargs p;
			vdynamic *exc = NULL;
			memset(&p, 0, sizeof(p));
			p.p = (char*)v + c->offsets[j];
			p.t = c->params[j];
			p.b = to_dyn(L, 3 + j, c->params[j]);
			if( protect(p_write, &p, &exc) ) return raise_hl(L, exc);
		}
		push_ref(L, (vdynamic*)v);
		return 1;
	}
	return luaL_error(L, "enum has no constructor '%s'", name);
}

static int l_enum_names( lua_State *L ) {
	vdynamic *cls = resolve_class(L, 1);
	hl_type *t = class_type(L, cls);
	int i;
	if( !t || t->kind != HENUM ) return 0;
	lua_createtable(L, t->tenum->nconstructs, 0);
	for(i=0;i<t->tenum->nconstructs;i++) {
		push_ustr(L, t->tenum->constructs[i].name);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* hl.struct{...} -> anonymous object */
static int l_struct( lua_State *L ) {
	vdynamic *o = (vdynamic*)hl_alloc_dynobj();
	push_ref(L, o);
	if( lua_istable(L, 1) ) {
		lua_pushnil(L);
		while( lua_next(L, 1) ) {
			if( lua_type(L, -2) == LUA_TSTRING ) {
				size_t len;
				const char *k = lua_tolstring(L, -2, &len);
				pargs p;
				vdynamic *exc = NULL;
				memset(&p, 0, sizeof(p));
				p.a = o;
				p.i = hl_hash_gen(utf8_to_utf16(k, len, NULL), true);
				p.b = to_dyn(L, -1, NULL);
				if( protect(p_set, &p, &exc) ) return raise_hl(L, exc);
			}
			lua_pop(L, 1);
		}
	}
	return 1;
}

/* hl.narray(n | table [, "dyn"|"i32"|"f64"|"f32"|"bool"]) -> native array (hl.NativeArray)
   The element kind must match what the game expects: a NativeArray<Int> is "i32". */
static int l_narray( lua_State *L ) {
	static const char *const kinds[] = { "dyn", "i32", "f64", "f32", "bool", NULL };
	hl_type *at = &hlt_dyn;
	varray *a;
	int n, i;
	switch( luaL_checkoption(L, 2, "dyn", kinds) ) {
	case 1: at = &hlt_i32; break;
	case 2: at = &hlt_f64; break;
	case 3: at = &hlt_f32; break;
	case 4: at = &hlt_bool; break;
	default: break;
	}
	n = lua_istable(L, 1) ? (int)lua_rawlen(L, 1) : (int)luaL_checkinteger(L, 1);
	if( n < 0 ) return luaL_error(L, "negative array size");
	a = hl_alloc_array(at, n);
	if( lua_istable(L, 1) ) {
		int sz = hl_type_size(at);
		for(i=0;i<n;i++) {
			vdynamic *v;
			lua_rawgeti(L, 1, i + 1);
			v = to_dyn(L, -1, at);
			if( at == &hlt_dyn )
				hl_aptr(a,vdynamic*)[i] = v;
			else {
				pargs p;
				vdynamic *exc = NULL;
				memset(&p, 0, sizeof(p));
				p.p = hl_aptr(a,char) + i * sz;
				p.t = at;
				p.b = v;
				if( protect(p_write, &p, &exc) ) return raise_hl(L, exc);
			}
			lua_pop(L, 1);
		}
	}
	push_ref(L, (vdynamic*)a);
	return 1;
}

static int l_closure( lua_State *L ) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	push_ref(L, make_closure(L, 1, NULL));
	return 1;
}

static int l_throw( lua_State *L ) {
	return raise_hl(L, to_dyn(L, 1, NULL));
}

static int l_isexception( lua_State *L ) {
	lua_pushboolean(L, to_exc(L, 1) != NULL);
	return 1;
}

static int l_addr( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	if( !v ) return 0;
	lua_pushfstring(L, "%p", (void*)v);
	return 1;
}

/* hl.ptr(v) -> integer identity: the native pointer inside an abstract / struct / bytes
   value, the object's address otherwise.  Stable for the object's lifetime; usable as a table key. */
static int l_ptr( lua_State *L ) {
	vdynamic *v = test_refval(L, 1);
	if( !v ) return 0;
	switch( v->t->kind ) {
	case HSTRUCT: case HABSTRACT: case HBYTES: case HREF: case HTYPE:
		lua_pushinteger(L, (lua_Integer)(int_val)v->v.ptr);
		break;
	default:
		lua_pushinteger(L, (lua_Integer)(int_val)v);
		break;
	}
	return 1;
}

/* hl.native("lib@name") -> callable reference to one of the game's native functions, or nil */
static int l_native( lua_State *L ) {
	const char *name = luaL_checkstring(L, 1);
	int i;
	for(i=0;i<g_native_fill;i++)
		if( strcmp(g_native_names[i], name) == 0 ) {
			vdynamic *c = hl_aptr(g_natives,vdynamic*)[i];
			if( !c ) return 0;
			new_ref(L, c);
			return 1;
		}
	return 0;
}

/* hl.natives() -> list of "lib@name" */
static int l_natives( lua_State *L ) {
	int i;
	lua_createtable(L, g_native_fill, 0);
	for(i=0;i<g_native_fill;i++) {
		lua_pushstring(L, g_native_names[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

/* hl.celem(carray, class, index) -> element of a C array (hl.CArray<T>) of objects or structs.
   No bounds are known here: the caller must stay inside the array. */
static int l_celem( lua_State *L ) {
	vdynamic *a = test_refval(L, 1);
	hl_type *t = class_type(L, resolve_class(L, 2));
	lua_Integer i = luaL_checkinteger(L, 3);
	char *p;
	int size;
	if( !a || (a->t->kind != HABSTRACT && a->t->kind != HBYTES) || !a->v.ptr ) return luaL_error(L, "not a C array");
	if( !t || (t->kind != HSTRUCT && t->kind != HOBJ) ) return luaL_error(L, "element type must be a class");
	if( i < 0 ) return luaL_error(L, "negative index");
	size = hl_get_obj_rt(t)->size;
	if( size & (HL_WSIZE - 1) ) size += HL_WSIZE - (size & (HL_WSIZE - 1));
	p = (char*)a->v.ptr + size * i;
	if( t->kind == HSTRUCT ) {
		hlref *nr = new_ref(L, box_ptr(t, p));
		nr->keep = handle_alloc(a);
	} else
		push_ref(L, (vdynamic*)p);
	return 1;
}

static int l_hookid( lua_State *L ) {
	const char *name = luaL_checkstring(L, 1);
	int i;
	for(i=0;i<g_nhooks;i++)
		if( strcmp(g_hook_names[i], name) == 0 ) { lua_pushinteger(L, i); return 1; }
	return 0;
}

static int l_hookname( lua_State *L ) {
	lua_Integer i = luaL_checkinteger(L, 1);
	if( i < 0 || i >= g_nhooks ) return 0;
	lua_pushstring(L, g_hook_names[i]);
	return 1;
}

static int l_nhooks( lua_State *L ) {
	lua_pushinteger(L, g_nhooks);
	return 1;
}

static int l_sethook( lua_State *L ) {
	lua_Integer i = luaL_checkinteger(L, 1);
	if( i < 0 || i >= g_nhooks ) return luaL_error(L, "invalid hook id");
	g_hooked[i] = lua_toboolean(L, 2) ? 1 : 0;
	return 0;
}

static int l_setdispatch( lua_State *L ) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	luaL_unref(L, LUA_REGISTRYINDEX, g_dispatch_ref);
	lua_pushvalue(L, 1);
	g_dispatch_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

static int l_setconvert( lua_State *L ) {
	luaL_checktype(L, 1, LUA_TFUNCTION);
	luaL_unref(L, LUA_REGISTRYINDEX, g_convert_ref);
	lua_pushvalue(L, 1);
	g_convert_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	return 0;
}

static int l_log( lua_State *L ) {
	log_line("%s", luaL_checkstring(L, 1));
	return 0;
}

static int l_home( lua_State *L ) {
	lua_pushstring(L, g_home);
	return 1;
}

static int l_mtime( lua_State *L ) {
	struct stat st;
	if( stat(luaL_checkstring(L, 1), &st) != 0 ) return 0;
	lua_pushinteger(L, (lua_Integer)st.st_mtime);
	return 1;
}

/* hl.listdir(path) -> { {name=, dir=bool}, ... } */
static int l_listdir( lua_State *L ) {
	const char *path = luaL_checkstring(L, 1);
	int n = 0;
	lua_newtable(L);
#ifdef _WIN32
	{
		WIN32_FIND_DATAA fd;
		HANDLE h;
		lua_pushfstring(L, "%s\\*", path);
		h = FindFirstFileA(lua_tostring(L, -1), &fd);
		lua_pop(L, 1);
		if( h == INVALID_HANDLE_VALUE ) return 1;
		do {
			if( strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0 ) continue;
			lua_createtable(L, 0, 2);
			lua_pushstring(L, fd.cFileName); lua_setfield(L, -2, "name");
			lua_pushboolean(L, (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0); lua_setfield(L, -2, "dir");
			lua_rawseti(L, -2, ++n);
		} while( FindNextFileA(h, &fd) );
		FindClose(h);
	}
#else
	{
		DIR *d = opendir(path);
		struct dirent *e;
		if( !d ) return 1;
		while( (e = readdir(d)) != NULL ) {
			struct stat st;
			if( strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0 ) continue;
			lua_createtable(L, 0, 2);
			lua_pushstring(L, e->d_name); lua_setfield(L, -2, "name");
			lua_pushfstring(L, "%s/%s", path, e->d_name);
			lua_pushboolean(L, stat(lua_tostring(L, -1), &st) == 0 && S_ISDIR(st.st_mode));
			lua_remove(L, -2);
			lua_setfield(L, -2, "dir");
			lua_rawseti(L, -2, ++n);
		}
		closedir(d);
	}
#endif
	return 1;
}

static const luaL_Reg HL_FUNCS[] = {
	{ "class", l_class }, { "classes", l_classes }, { "new", l_new }, { "typeof", l_typeof },
	{ "classof", l_classof }, { "super", l_super }, { "is", l_is }, { "fields", l_fields },
	{ "tostring", l_tostring }, { "enum", l_enum }, { "enum_names", l_enum_names },
	{ "struct", l_struct }, { "narray", l_narray }, { "closure", l_closure },
	{ "throw", l_throw }, { "isexception", l_isexception }, { "addr", l_addr }, { "ptr", l_ptr },
	{ "native", l_native }, { "natives", l_natives }, { "celem", l_celem },
	{ "hookid", l_hookid }, { "hookname", l_hookname }, { "nhooks", l_nhooks }, { "sethook", l_sethook },
	{ "setdispatch", l_setdispatch }, { "setconvert", l_setconvert },
	{ "log", l_log }, { "home", l_home }, { "mtime", l_mtime }, { "listdir", l_listdir },
	{ NULL, NULL }
};

/* ------------------------------------------------------------- natives */

HL_PRIM bool HL_NAME(hooked)( int id ) {
	if( !g_hooked || !g_hooked[id] ) return false;
	if( hl_thread_id() != g_main_thread ) return false;	/* Lua runs on the main thread only */
	if( g_bypass == id ) {
		g_bypass = -1;
		return false;
	}
	return true;
}

HL_PRIM void HL_NAME(begin)( int id, vdynamic *self ) {
	hook_frame *f;
	if( g_nframes == g_frame_cap ) {
		if( g_frame_cap >= 4096 ) hl_error("mosalua: hooks nested too deeply");
		g_frame_cap = g_frame_cap ? g_frame_cap * 2 : 64;
		g_frames = (hook_frame*)realloc(g_frames, sizeof(hook_frame) * g_frame_cap);
	}
	if( !g_args || g_argtop + 32 > g_args->size ) {
		int ncap = g_args ? g_args->size * 2 : 1024;
		varray *na = hl_alloc_array(&hlt_dyn, ncap);
		if( g_args ) memcpy(hl_aptr(na,vdynamic*), hl_aptr(g_args,vdynamic*), sizeof(void*) * g_argtop);
		g_args = na;
	}
	f = g_frames + g_nframes++;
	f->id = id;
	f->orig = (vclosure*)self;
	f->nargs = 0;
	f->orig_called = false;
	hl_aptr(g_args,vdynamic*)[g_argtop++] = NULL;	/* slot for the return value */
	f->base = g_argtop;
}

HL_PRIM void HL_NAME(arg)( vdynamic *v ) {
	hook_frame *f = g_frames + g_nframes - 1;
	if( f->nargs >= 16 ) return;
	hl_aptr(g_args,vdynamic*)[g_argtop++] = v;
	f->nargs++;
}

static int invoke_body( lua_State *L ) {
	int depth = (int)lua_tointeger(L, 1);
	hook_frame *f = g_frames + depth;
	int n = f->nargs, i, base = f->base;
	hlref *r;
	vdynamic *ret;
	luaL_checkstack(L, n + 6, "too many arguments");
	lua_rawgeti(L, LUA_REGISTRYINDEX, g_dispatch_ref);
	lua_pushinteger(L, f->id);
	/* "orig": the function's own closure, flagged to skip the hook check once */
	lua_rawgeti(L, LUA_REGISTRYINDEX, g_orig_ref);
	if( lua_rawgeti(L, -1, f->id) != LUA_TUSERDATA ) {
		lua_pop(L, 1);
		r = new_ref(L, (vdynamic*)f->orig);
		r->bypass = f->id;
		lua_pushvalue(L, -1);
		lua_rawseti(L, -3, f->id);
	}
	lua_remove(L, -2);
	for(i=0;i<n;i++)
		push_dyn(L, hl_aptr(g_args,vdynamic*)[base + i]);
	lua_call(L, n + 2, 1);
	f = g_frames + depth;	/* the frame array may have been reallocated */
	ret = to_dyn(L, -1, f->orig->t->fun->ret);
	hl_aptr(g_args,vdynamic*)[f->base - 1] = ret;
	return 0;
}

HL_PRIM vdynamic *HL_NAME(invoke)( int id ) {
	lua_State *L = g_L;
	int depth = g_nframes - 1;
	hook_frame *f = g_frames + depth;
	int top, st;
	vdynamic *ret = NULL, *exc = NULL;
	bool has_exc = false;
	drain_pending();
	top = lua_gettop(L);
	if( !lua_checkstack(L, 8) ) hl_error("mosalua: Lua stack overflow");
	lua_pushcfunction(L, msgh);
	lua_pushcfunction(L, invoke_body);
	lua_pushinteger(L, depth);
	st = lua_pcall(L, 1, 0, top + 1);
	f = g_frames + depth;
	if( st == LUA_OK )
		ret = hl_aptr(g_args,vdynamic*)[f->base - 1];
	else {
		hlexc *e = to_exc(L, -1);
		if( e && e->h >= 0 ) {
			exc = hl_aptr(g_args,vdynamic*)[f->base - 1] = hl_aptr(g_handles,vdynamic*)[e->h];
			has_exc = true;
		} else
			log_line("ERROR in hook dispatch for %s: %s", id < g_nhooks ? g_hook_names[id] : "?", lua_tostring(L, -1));
	}
	lua_settop(L, top);
	if( st != LUA_OK && !has_exc && !f->orig_called ) {
		/* the Lua side failed before running the game's own code: run it now */
		vdynamic *args[HL_MAX_DYN_ARGS + 1];
		vclosure *orig = f->orig;
		int n = f->nargs > HL_MAX_DYN_ARGS ? HL_MAX_DYN_ARGS : f->nargs;
		bool is_exc = false;
		memcpy(args, hl_aptr(g_args,vdynamic*) + f->base, sizeof(void*) * n);
		g_argtop = f->base - 1;
		g_nframes = depth;
		g_bypass = id;
		ret = dyn_call(orig, args, n, &is_exc);
		if( g_bypass == id ) g_bypass = -1;
		if( is_exc ) hl_throw(ret);
		return ret;
	}
	g_argtop = f->base - 1;
	g_nframes = depth;
	if( has_exc ) hl_throw(exc);
	return ret;
}

/* names of the game's native functions, '\n' separated; native() is then called once per name */
HL_PRIM void HL_NAME(natives)( vbyte *table ) {
	const uchar *t = (const uchar*)table;
	int n = 0, i, start = 0, k = 0, j;
	if( g_natives || !t ) return;
	for(i=0;t[i];i++) if( t[i] == '\n' ) n++;
	g_native_names = (char**)calloc(n + 1, sizeof(char*));
	for(i=0;t[i];i++) {
		if( t[i] != '\n' ) continue;
		g_native_names[k] = (char*)malloc(i - start + 1);
		for(j=start;j<i;j++) g_native_names[k][j - start] = (char)t[j];
		g_native_names[k][i - start] = 0;
		k++;
		start = i + 1;
	}
	g_nnatives = n;
	hl_add_root(&g_natives);
	g_natives = hl_alloc_array(&hlt_dyn, n + 1);
}

HL_PRIM void HL_NAME(native)( vdynamic *closure ) {
	if( !g_natives || g_native_fill >= g_nnatives ) return;
	hl_aptr(g_natives,vdynamic*)[g_native_fill++] = closure;
}

static bool file_exists( const char *path ) {
	struct stat st;
	return stat(path, &st) == 0;
}

static void find_home( void ) {
	const char *env = getenv("MOSALUA_HOME");
	if( env && *env ) {
		snprintf(g_home, sizeof(g_home), "%s", env);
		return;
	}
#ifdef _WIN32
	{
		HMODULE m = NULL;
		char buf[1024];
		if( GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)&find_home, &m)
			&& GetModuleFileNameA(m, buf, sizeof(buf)) > 0 ) {
			char *s = strrchr(buf, '\\');
			if( s ) {
				*s = 0;
				snprintf(g_home, sizeof(g_home), "%s", buf);
				return;
			}
		}
	}
#endif
	strcpy(g_home, ".");
}

typedef struct { vdynamic *types; const uchar *table; } boot_args;

static int boot_body( lua_State *L ) {
	char path[1200];
	luaL_openlibs(L);

	luaL_newmetatable(L, REF_MT);
	lua_pushcfunction(L, ref_index); lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, ref_newindex); lua_setfield(L, -2, "__newindex");
	lua_pushcfunction(L, ref_call); lua_setfield(L, -2, "__call");
	lua_pushcfunction(L, ref_tostring); lua_setfield(L, -2, "__tostring");
	lua_pushcfunction(L, ref_len); lua_setfield(L, -2, "__len");
	lua_pushcfunction(L, ref_eq); lua_setfield(L, -2, "__eq");
	lua_pushcfunction(L, ref_gc); lua_setfield(L, -2, "__gc");
	lua_pushliteral(L, "game object"); lua_setfield(L, -2, "__name");
	lua_pushboolean(L, 0); lua_setfield(L, -2, "__metatable");
	g_refmt_ref = luaL_ref(L, LUA_REGISTRYINDEX);
	lua_newtable(L);	/* hook id -> cached "orig" closure reference */
	g_orig_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	luaL_newmetatable(L, EXC_MT);
	lua_pushcfunction(L, exc_tostring); lua_setfield(L, -2, "__tostring");
	lua_pushcfunction(L, exc_gc); lua_setfield(L, -2, "__gc");
	lua_pushcfunction(L, exc_index); lua_setfield(L, -2, "__index");
	lua_pushboolean(L, 0); lua_setfield(L, -2, "__metatable");
	lua_pop(L, 1);

	lua_newtable(L);	/* pointer -> userdata cache, weak values */
	lua_newtable(L);
	lua_pushliteral(L, "v"); lua_setfield(L, -2, "__mode");
	lua_setmetatable(L, -2);
	g_cache_ref = luaL_ref(L, LUA_REGISTRYINDEX);

	luaL_newlib(L, HL_FUNCS);
	lua_pushliteral(L, MOSALUA_VERSION); lua_setfield(L, -2, "version");
	lua_pushinteger(L, HL_VERSION); lua_setfield(L, -2, "hl_version");
#ifdef _WIN32
	lua_pushliteral(L, "\\");
#else
	lua_pushliteral(L, "/");
#endif
	lua_setfield(L, -2, "sep");
	lua_setglobal(L, "hl");

	/* a runtime dropped next to the mods overrides the embedded one (lets fixes ship as plain Lua) */
	snprintf(path, sizeof(path), "%s/mods/_runtime/mosa.lua", g_home);
	if( file_exists(path) ) {
		log_line("using runtime override %s", path);
		if( luaL_loadfile(L, path) != LUA_OK ) return lua_error(L);
	} else if( luaL_loadbuffer(L, (const char*)mosa_lua_src, mosa_lua_len, "=mosa.lua") != LUA_OK )
		return lua_error(L);
	lua_call(L, 0, 0);
	return 0;
}

HL_PRIM void HL_NAME(boot)( vdynamic *types, vbyte *table ) {
	char path[1200];
	lua_State *L;
	const uchar *t = (const uchar*)table;
	vdynamic *scls;
	int n = 0, i, st;
	if( g_booted ) return;
	g_booted = true;
	g_main_thread = hl_thread_id();
	find_home();
	snprintf(path, sizeof(path), "%s/mods/mosalua.log", g_home);
	g_log = fopen(path, "w");
	log_line("mosalua %s starting (%s)", MOSALUA_VERSION, LUA_RELEASE);

	/* static HashLink types used for protected calls and Lua callbacks */
	memset(&tf_thunk, 0, sizeof(tf_thunk));
	tf_thunk.ret = &hlt_dyn;
	t_thunk.kind = HFUN;
	t_thunk.fun = &tf_thunk;
	c_thunk.t = &t_thunk;
	c_thunk.fun = (void*)protect_thunk;
	c_thunk.hasValue = 0;
	memset(&tf_cb, 0, sizeof(tf_cb));
	t_cb_args[0] = &hlt_bytes;
	t_cb_args[1] = &hlt_array;
	tf_cb.args = t_cb_args;
	tf_cb.nargs = 2;
	tf_cb.ret = &hlt_dyn;
	t_cb.kind = HFUN;
	t_cb.fun = &tf_cb;

	hl_add_root(&g_handles);
	hl_add_root(&g_args);
	detect_f32_bug();

	if( types == NULL ) {
		log_line("ERROR: type registry is null, mods disabled");
		return;
	}
	if( types->t->kind == HOBJ ) {
		vdynamic *h = hl_obj_get_field(types, hl_hash_utf8("h"));
		g_types_map = h ? h->v.ptr : NULL;
	} else
		g_types_map = types->v.ptr;
	if( !g_types_map ) {
		log_line("ERROR: cannot read the type registry, mods disabled");
		return;
	}
	scls = hl_hbget(g_types_map, (vbyte*)USTR("String"));
	if( scls ) {
		vdynamic *ty = hl_obj_get_field(scls, hl_hash_utf8("__type__"));
		if( ty && ty->t->kind == HTYPE ) g_tstring = (hl_type*)ty->v.ptr;
	}
	if( !g_tstring ) {
		log_line("ERROR: String class not found, mods disabled");
		return;
	}

	/* hook table: names separated by '\n', id = line number */
	if( t ) {
		for(i=0;t[i];i++) if( t[i] == '\n' ) n++;
		g_hook_names = (char**)calloc(n + 1, sizeof(char*));
		{
			int start = 0, k = 0, j;
			for(i=0;t[i];i++) {
				if( t[i] != '\n' ) continue;
				g_hook_names[k] = (char*)malloc(i - start + 1);
				for(j=start;j<i;j++) g_hook_names[k][j - start] = (char)t[j];
				g_hook_names[k][i - start] = 0;
				k++;
				start = i + 1;
			}
		}
		g_nhooks = n;
	}
	{
		unsigned char *flags = (unsigned char*)calloc(n + 1, 1);
		g_hooked = flags;
	}
	log_line("%d hookable functions, %d native functions, home = %s", g_nhooks, g_native_fill, g_home);

	L = luaL_newstate();
	if( !L ) {
		log_line("ERROR: cannot create Lua state");
		return;
	}
	g_L = L;
	lua_pushcfunction(L, msgh);
	lua_pushcfunction(L, boot_body);
	st = lua_pcall(L, 0, 0, 1);
	if( st != LUA_OK ) {
		hlexc *e = to_exc(L, -1);
		if( e ) push_exc_message(L, e);
		log_line("ERROR during startup: %s", lua_tostring(L, -1));
	}
	lua_settop(L, 0);
}

DEFINE_PRIM(_BOOL, hooked, _I32);
DEFINE_PRIM(_VOID, begin, _I32 _DYN);
DEFINE_PRIM(_VOID, arg, _DYN);
DEFINE_PRIM(_DYN, invoke, _I32);
DEFINE_PRIM(_VOID, boot, _DYN _BYTES);
DEFINE_PRIM(_VOID, natives, _BYTES);
DEFINE_PRIM(_VOID, native, _DYN);
