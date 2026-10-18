#!/usr/bin/env python3
"""Generate src/jni.zig from a JDK's jni.h.

Usage: gen_jni.py <path/to/jni.h> > src/jni.zig

Zig 0.17 has no @cImport, so the JNI function tables are declared by hand.
Rather than hand-typing ~230 function pointers (and risking an off-by-one
that silently calls the wrong JNI function), we parse the struct bodies out
of the real header.  Only the table layout comes from jni.h; the surrounding
helpers are written here.
"""
import re, sys

src = open(sys.argv[1]).read()

TYPES = {
    'jint': 'jint', 'jlong': 'jlong', 'jboolean': 'jboolean', 'jbyte': 'jbyte',
    'jchar': 'jchar', 'jshort': 'jshort', 'jfloat': 'jfloat', 'jdouble': 'jdouble',
    'jsize': 'jsize', 'void': 'void',
    'jobject': 'jobject', 'jclass': 'jclass', 'jstring': 'jstring', 'jthrowable': 'jthrowable',
    'jarray': 'jarray', 'jobjectArray': 'jobjectArray', 'jbooleanArray': 'jbooleanArray',
    'jbyteArray': 'jbyteArray', 'jcharArray': 'jcharArray', 'jshortArray': 'jshortArray',
    'jintArray': 'jintArray', 'jlongArray': 'jlongArray', 'jfloatArray': 'jfloatArray',
    'jdoubleArray': 'jdoubleArray', 'jweak': 'jweak',
    'jmethodID': 'jmethodID', 'jfieldID': 'jfieldID',
    'jobjectRefType': 'jobjectRefType',
}

def map_type(t):
    t = t.strip()
    t = re.sub(r'\s*\*', ' *', t)   # normalise 'char*' / 'char *' / 'char  *'
    t = re.sub(r'\s+', ' ', t)
    t = t.replace(' * *', ' **')
    if t == 'JavaVM **': return '*?*JavaVM'
    if t == 'JNIEnv *' or t == 'JNIEnv*': return '*JNIEnv'
    if t == 'JavaVM *' or t == 'JavaVM*': return '*JavaVM'
    if t == 'JNIEnv **': return '*?*JNIEnv'
    if t in ('void **',): return '*?*anyopaque'
    if t == 'void *': return '?*anyopaque'
    if t == 'const char *': return '[*:0]const u8'
    if t == 'char *': return '[*]u8'
    if t == 'const jchar *': return '[*]const jchar'
    if t == 'const jbyte *': return '[*]const jbyte'
    if t == 'const jvalue *': return '[*]const jvalue'
    if t == 'const JNINativeMethod *': return '[*]const JNINativeMethod'
    if t == 'const jboolean *': return '[*]const jboolean'
    if t == 'jboolean *': return '?*jboolean'
    if t == 'va_list': return '?*anyopaque'
    m = re.match(r'const (j\w+) \*$', t)
    if m: return f'[*]const {TYPES[m.group(1)]}'
    m = re.match(r'(j\w+) \*$', t)
    if m: return f'[*]{TYPES[m.group(1)]}'
    if t in TYPES: return TYPES[t]
    raise SystemExit(f'unmapped type: {t!r}')

def emit_struct(name, cname):
    body = re.search(r'struct %s \{(.*?)\n\};' % cname, src, re.S).group(1)
    body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
    out = [f'pub const {name} = extern struct {{']
    reserved = 0
    # split into declarations by ';'
    for decl in [d.strip() for d in body.split(';') if d.strip()]:
        decl = re.sub(r'\s+', ' ', decl)
        m = re.match(r'void \*(reserved\d+)$', decl)
        if m:
            out.append(f'    {m.group(1)}: ?*anyopaque,')
            continue
        m = re.match(r'(.+?)\(JNICALL \*(\w+)\) ?\((.*)\)$', decl)
        if not m:
            raise SystemExit(f'cannot parse: {decl!r}')
        ret, fname, params = m.group(1), m.group(2), m.group(3)
        ret_t = map_type(ret)
        plist = [p.strip() for p in params.split(',')]
        if any(p == '...' for p in plist):
            # variadic: declare as opaque pointer; callers must use the `A` variants
            out.append(f'    {fname}: ?*const anyopaque, // variadic, use {fname}A')
            continue
        ptypes = []
        for p in plist:
            if p == 'void': continue
            # strip the parameter name
            pm = re.match(r'(.+?)\s*(\w+)$', p)
            if pm and not p.endswith('*'):
                ptypes.append(map_type(pm.group(1)))
            else:
                ptypes.append(map_type(p))
        out.append(f'    {fname}: *const fn ({", ".join(ptypes)}) callconv(.c) {ret_t},')
    out.append('};')
    return '\n'.join(out)

header = '''//! JNI bindings for Zig, generated from the JDK's jni.h by tools/gen_jni.py.
//! Do not edit by hand; regenerate with:
//!     python3 tools/gen_jni.py "$JAVA_HOME/include/jni.h" > src/jni.zig
//!
//! Only the function-table layouts are derived from the header.  Primitive
//! type aliases and the small helper layer at the bottom are maintained here.

pub const jint = i32;
pub const jlong = i64;
pub const jbyte = i8;
pub const jboolean = u8;
pub const jchar = u16;
pub const jshort = i16;
pub const jfloat = f32;
pub const jdouble = f64;
pub const jsize = jint;

pub const jobject = ?*anyopaque;
pub const jclass = jobject;
pub const jthrowable = jobject;
pub const jstring = jobject;
pub const jarray = jobject;
pub const jbooleanArray = jarray;
pub const jbyteArray = jarray;
pub const jcharArray = jarray;
pub const jshortArray = jarray;
pub const jintArray = jarray;
pub const jlongArray = jarray;
pub const jfloatArray = jarray;
pub const jdoubleArray = jarray;
pub const jobjectArray = jarray;
pub const jweak = jobject;

pub const jmethodID = ?*anyopaque;
pub const jfieldID = ?*anyopaque;

pub const jobjectRefType = c_int;

pub const jvalue = extern union {
    z: jboolean,
    b: jbyte,
    c: jchar,
    s: jshort,
    i: jint,
    j: jlong,
    f: jfloat,
    d: jdouble,
    l: jobject,
};

pub const JNINativeMethod = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    fnPtr: ?*anyopaque,
};

pub const JNI_FALSE: jboolean = 0;
pub const JNI_TRUE: jboolean = 1;

pub const JNI_OK: jint = 0;
pub const JNI_ERR: jint = -1;
pub const JNI_EDETACHED: jint = -2;
pub const JNI_EVERSION: jint = -3;
pub const JNI_ENOMEM: jint = -4;
pub const JNI_EEXIST: jint = -5;
pub const JNI_EINVAL: jint = -6;

pub const JNI_VERSION_1_6: jint = 0x00010006;
pub const JNI_VERSION_1_8: jint = 0x00010008;

pub const JNIEnv = extern struct {
    f: *const JNINativeInterface,
};

pub const JavaVM = extern struct {
    f: *const JNIInvokeInterface,
};

pub const JavaVMOption = extern struct {
    optionString: [*:0]const u8,
    extraInfo: ?*anyopaque = null,
};

pub const JavaVMInitArgs = extern struct {
    version: jint,
    nOptions: jint,
    options: [*]JavaVMOption,
    ignoreUnrecognized: jboolean,
};

pub const JavaVMAttachArgs = extern struct {
    version: jint,
    name: ?[*:0]const u8 = null,
    group: jobject = null,
};

pub const CreateJavaVMFn = *const fn (*?*JavaVM, *?*JNIEnv, *JavaVMInitArgs) callconv(.c) jint;
pub const GetCreatedJavaVMsFn = *const fn ([*]?*JavaVM, jsize, *jsize) callconv(.c) jint;

'''
print(header)
print(emit_struct('JNINativeInterface', 'JNINativeInterface_'))
print()
print(emit_struct('JNIInvokeInterface', 'JNIInvokeInterface_'))
