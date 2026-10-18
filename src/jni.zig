//! JNI bindings for Zig, generated from the JDK's jni.h by tools/gen_jni.py.
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

pub const JNINativeInterface = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    reserved3: ?*anyopaque,
    GetVersion: *const fn (*JNIEnv) callconv(.c) jint,
    DefineClass: *const fn (*JNIEnv, [*:0]const u8, jobject, [*]const jbyte, jsize) callconv(.c) jclass,
    FindClass: *const fn (*JNIEnv, [*:0]const u8) callconv(.c) jclass,
    FromReflectedMethod: *const fn (*JNIEnv, jobject) callconv(.c) jmethodID,
    FromReflectedField: *const fn (*JNIEnv, jobject) callconv(.c) jfieldID,
    ToReflectedMethod: *const fn (*JNIEnv, jclass, jmethodID, jboolean) callconv(.c) jobject,
    GetSuperclass: *const fn (*JNIEnv, jclass) callconv(.c) jclass,
    IsAssignableFrom: *const fn (*JNIEnv, jclass, jclass) callconv(.c) jboolean,
    ToReflectedField: *const fn (*JNIEnv, jclass, jfieldID, jboolean) callconv(.c) jobject,
    Throw: *const fn (*JNIEnv, jthrowable) callconv(.c) jint,
    ThrowNew: *const fn (*JNIEnv, jclass, [*:0]const u8) callconv(.c) jint,
    ExceptionOccurred: *const fn (*JNIEnv) callconv(.c) jthrowable,
    ExceptionDescribe: *const fn (*JNIEnv) callconv(.c) void,
    ExceptionClear: *const fn (*JNIEnv) callconv(.c) void,
    FatalError: *const fn (*JNIEnv, [*:0]const u8) callconv(.c) void,
    PushLocalFrame: *const fn (*JNIEnv, jint) callconv(.c) jint,
    PopLocalFrame: *const fn (*JNIEnv, jobject) callconv(.c) jobject,
    NewGlobalRef: *const fn (*JNIEnv, jobject) callconv(.c) jobject,
    DeleteGlobalRef: *const fn (*JNIEnv, jobject) callconv(.c) void,
    DeleteLocalRef: *const fn (*JNIEnv, jobject) callconv(.c) void,
    IsSameObject: *const fn (*JNIEnv, jobject, jobject) callconv(.c) jboolean,
    NewLocalRef: *const fn (*JNIEnv, jobject) callconv(.c) jobject,
    EnsureLocalCapacity: *const fn (*JNIEnv, jint) callconv(.c) jint,
    AllocObject: *const fn (*JNIEnv, jclass) callconv(.c) jobject,
    NewObject: ?*const anyopaque, // variadic, use NewObjectA
    NewObjectV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jobject,
    NewObjectA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject,
    GetObjectClass: *const fn (*JNIEnv, jobject) callconv(.c) jclass,
    IsInstanceOf: *const fn (*JNIEnv, jobject, jclass) callconv(.c) jboolean,
    GetMethodID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallObjectMethod: ?*const anyopaque, // variadic, use CallObjectMethodA
    CallObjectMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jobject,
    CallObjectMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jobject,
    CallBooleanMethod: ?*const anyopaque, // variadic, use CallBooleanMethodA
    CallBooleanMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jboolean,
    CallBooleanMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jboolean,
    CallByteMethod: ?*const anyopaque, // variadic, use CallByteMethodA
    CallByteMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jbyte,
    CallByteMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jbyte,
    CallCharMethod: ?*const anyopaque, // variadic, use CallCharMethodA
    CallCharMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jchar,
    CallCharMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jchar,
    CallShortMethod: ?*const anyopaque, // variadic, use CallShortMethodA
    CallShortMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jshort,
    CallShortMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jshort,
    CallIntMethod: ?*const anyopaque, // variadic, use CallIntMethodA
    CallIntMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jint,
    CallIntMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jint,
    CallLongMethod: ?*const anyopaque, // variadic, use CallLongMethodA
    CallLongMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jlong,
    CallLongMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jlong,
    CallFloatMethod: ?*const anyopaque, // variadic, use CallFloatMethodA
    CallFloatMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jfloat,
    CallFloatMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jfloat,
    CallDoubleMethod: ?*const anyopaque, // variadic, use CallDoubleMethodA
    CallDoubleMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) jdouble,
    CallDoubleMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) jdouble,
    CallVoidMethod: ?*const anyopaque, // variadic, use CallVoidMethodA
    CallVoidMethodV: *const fn (*JNIEnv, jobject, jmethodID, ?*anyopaque) callconv(.c) void,
    CallVoidMethodA: *const fn (*JNIEnv, jobject, jmethodID, [*]const jvalue) callconv(.c) void,
    CallNonvirtualObjectMethod: ?*const anyopaque, // variadic, use CallNonvirtualObjectMethodA
    CallNonvirtualObjectMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jobject,
    CallNonvirtualObjectMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject,
    CallNonvirtualBooleanMethod: ?*const anyopaque, // variadic, use CallNonvirtualBooleanMethodA
    CallNonvirtualBooleanMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jboolean,
    CallNonvirtualBooleanMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jboolean,
    CallNonvirtualByteMethod: ?*const anyopaque, // variadic, use CallNonvirtualByteMethodA
    CallNonvirtualByteMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jbyte,
    CallNonvirtualByteMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jbyte,
    CallNonvirtualCharMethod: ?*const anyopaque, // variadic, use CallNonvirtualCharMethodA
    CallNonvirtualCharMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jchar,
    CallNonvirtualCharMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jchar,
    CallNonvirtualShortMethod: ?*const anyopaque, // variadic, use CallNonvirtualShortMethodA
    CallNonvirtualShortMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jshort,
    CallNonvirtualShortMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jshort,
    CallNonvirtualIntMethod: ?*const anyopaque, // variadic, use CallNonvirtualIntMethodA
    CallNonvirtualIntMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jint,
    CallNonvirtualIntMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jint,
    CallNonvirtualLongMethod: ?*const anyopaque, // variadic, use CallNonvirtualLongMethodA
    CallNonvirtualLongMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jlong,
    CallNonvirtualLongMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jlong,
    CallNonvirtualFloatMethod: ?*const anyopaque, // variadic, use CallNonvirtualFloatMethodA
    CallNonvirtualFloatMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jfloat,
    CallNonvirtualFloatMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jfloat,
    CallNonvirtualDoubleMethod: ?*const anyopaque, // variadic, use CallNonvirtualDoubleMethodA
    CallNonvirtualDoubleMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) jdouble,
    CallNonvirtualDoubleMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) jdouble,
    CallNonvirtualVoidMethod: ?*const anyopaque, // variadic, use CallNonvirtualVoidMethodA
    CallNonvirtualVoidMethodV: *const fn (*JNIEnv, jobject, jclass, jmethodID, ?*anyopaque) callconv(.c) void,
    CallNonvirtualVoidMethodA: *const fn (*JNIEnv, jobject, jclass, jmethodID, [*]const jvalue) callconv(.c) void,
    GetFieldID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID,
    GetObjectField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jobject,
    GetBooleanField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jboolean,
    GetByteField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jbyte,
    GetCharField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jchar,
    GetShortField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jshort,
    GetIntField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jint,
    GetLongField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jlong,
    GetFloatField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jfloat,
    GetDoubleField: *const fn (*JNIEnv, jobject, jfieldID) callconv(.c) jdouble,
    SetObjectField: *const fn (*JNIEnv, jobject, jfieldID, jobject) callconv(.c) void,
    SetBooleanField: *const fn (*JNIEnv, jobject, jfieldID, jboolean) callconv(.c) void,
    SetByteField: *const fn (*JNIEnv, jobject, jfieldID, jbyte) callconv(.c) void,
    SetCharField: *const fn (*JNIEnv, jobject, jfieldID, jchar) callconv(.c) void,
    SetShortField: *const fn (*JNIEnv, jobject, jfieldID, jshort) callconv(.c) void,
    SetIntField: *const fn (*JNIEnv, jobject, jfieldID, jint) callconv(.c) void,
    SetLongField: *const fn (*JNIEnv, jobject, jfieldID, jlong) callconv(.c) void,
    SetFloatField: *const fn (*JNIEnv, jobject, jfieldID, jfloat) callconv(.c) void,
    SetDoubleField: *const fn (*JNIEnv, jobject, jfieldID, jdouble) callconv(.c) void,
    GetStaticMethodID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jmethodID,
    CallStaticObjectMethod: ?*const anyopaque, // variadic, use CallStaticObjectMethodA
    CallStaticObjectMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jobject,
    CallStaticObjectMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jobject,
    CallStaticBooleanMethod: ?*const anyopaque, // variadic, use CallStaticBooleanMethodA
    CallStaticBooleanMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jboolean,
    CallStaticBooleanMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jboolean,
    CallStaticByteMethod: ?*const anyopaque, // variadic, use CallStaticByteMethodA
    CallStaticByteMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jbyte,
    CallStaticByteMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jbyte,
    CallStaticCharMethod: ?*const anyopaque, // variadic, use CallStaticCharMethodA
    CallStaticCharMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jchar,
    CallStaticCharMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jchar,
    CallStaticShortMethod: ?*const anyopaque, // variadic, use CallStaticShortMethodA
    CallStaticShortMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jshort,
    CallStaticShortMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jshort,
    CallStaticIntMethod: ?*const anyopaque, // variadic, use CallStaticIntMethodA
    CallStaticIntMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jint,
    CallStaticIntMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jint,
    CallStaticLongMethod: ?*const anyopaque, // variadic, use CallStaticLongMethodA
    CallStaticLongMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jlong,
    CallStaticLongMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jlong,
    CallStaticFloatMethod: ?*const anyopaque, // variadic, use CallStaticFloatMethodA
    CallStaticFloatMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jfloat,
    CallStaticFloatMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jfloat,
    CallStaticDoubleMethod: ?*const anyopaque, // variadic, use CallStaticDoubleMethodA
    CallStaticDoubleMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) jdouble,
    CallStaticDoubleMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) jdouble,
    CallStaticVoidMethod: ?*const anyopaque, // variadic, use CallStaticVoidMethodA
    CallStaticVoidMethodV: *const fn (*JNIEnv, jclass, jmethodID, ?*anyopaque) callconv(.c) void,
    CallStaticVoidMethodA: *const fn (*JNIEnv, jclass, jmethodID, [*]const jvalue) callconv(.c) void,
    GetStaticFieldID: *const fn (*JNIEnv, jclass, [*:0]const u8, [*:0]const u8) callconv(.c) jfieldID,
    GetStaticObjectField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jobject,
    GetStaticBooleanField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jboolean,
    GetStaticByteField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jbyte,
    GetStaticCharField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jchar,
    GetStaticShortField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jshort,
    GetStaticIntField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jint,
    GetStaticLongField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jlong,
    GetStaticFloatField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jfloat,
    GetStaticDoubleField: *const fn (*JNIEnv, jclass, jfieldID) callconv(.c) jdouble,
    SetStaticObjectField: *const fn (*JNIEnv, jclass, jfieldID, jobject) callconv(.c) void,
    SetStaticBooleanField: *const fn (*JNIEnv, jclass, jfieldID, jboolean) callconv(.c) void,
    SetStaticByteField: *const fn (*JNIEnv, jclass, jfieldID, jbyte) callconv(.c) void,
    SetStaticCharField: *const fn (*JNIEnv, jclass, jfieldID, jchar) callconv(.c) void,
    SetStaticShortField: *const fn (*JNIEnv, jclass, jfieldID, jshort) callconv(.c) void,
    SetStaticIntField: *const fn (*JNIEnv, jclass, jfieldID, jint) callconv(.c) void,
    SetStaticLongField: *const fn (*JNIEnv, jclass, jfieldID, jlong) callconv(.c) void,
    SetStaticFloatField: *const fn (*JNIEnv, jclass, jfieldID, jfloat) callconv(.c) void,
    SetStaticDoubleField: *const fn (*JNIEnv, jclass, jfieldID, jdouble) callconv(.c) void,
    NewString: *const fn (*JNIEnv, [*]const jchar, jsize) callconv(.c) jstring,
    GetStringLength: *const fn (*JNIEnv, jstring) callconv(.c) jsize,
    GetStringChars: *const fn (*JNIEnv, jstring, ?*jboolean) callconv(.c) [*]const jchar,
    ReleaseStringChars: *const fn (*JNIEnv, jstring, [*]const jchar) callconv(.c) void,
    NewStringUTF: *const fn (*JNIEnv, [*:0]const u8) callconv(.c) jstring,
    GetStringUTFLength: *const fn (*JNIEnv, jstring) callconv(.c) jsize,
    GetStringUTFChars: *const fn (*JNIEnv, jstring, ?*jboolean) callconv(.c) [*:0]const u8,
    ReleaseStringUTFChars: *const fn (*JNIEnv, jstring, [*:0]const u8) callconv(.c) void,
    GetArrayLength: *const fn (*JNIEnv, jarray) callconv(.c) jsize,
    NewObjectArray: *const fn (*JNIEnv, jsize, jclass, jobject) callconv(.c) jobjectArray,
    GetObjectArrayElement: *const fn (*JNIEnv, jobjectArray, jsize) callconv(.c) jobject,
    SetObjectArrayElement: *const fn (*JNIEnv, jobjectArray, jsize, jobject) callconv(.c) void,
    NewBooleanArray: *const fn (*JNIEnv, jsize) callconv(.c) jbooleanArray,
    NewByteArray: *const fn (*JNIEnv, jsize) callconv(.c) jbyteArray,
    NewCharArray: *const fn (*JNIEnv, jsize) callconv(.c) jcharArray,
    NewShortArray: *const fn (*JNIEnv, jsize) callconv(.c) jshortArray,
    NewIntArray: *const fn (*JNIEnv, jsize) callconv(.c) jintArray,
    NewLongArray: *const fn (*JNIEnv, jsize) callconv(.c) jlongArray,
    NewFloatArray: *const fn (*JNIEnv, jsize) callconv(.c) jfloatArray,
    NewDoubleArray: *const fn (*JNIEnv, jsize) callconv(.c) jdoubleArray,
    GetBooleanArrayElements: *const fn (*JNIEnv, jbooleanArray, ?*jboolean) callconv(.c) ?*jboolean,
    GetByteArrayElements: *const fn (*JNIEnv, jbyteArray, ?*jboolean) callconv(.c) [*]jbyte,
    GetCharArrayElements: *const fn (*JNIEnv, jcharArray, ?*jboolean) callconv(.c) [*]jchar,
    GetShortArrayElements: *const fn (*JNIEnv, jshortArray, ?*jboolean) callconv(.c) [*]jshort,
    GetIntArrayElements: *const fn (*JNIEnv, jintArray, ?*jboolean) callconv(.c) [*]jint,
    GetLongArrayElements: *const fn (*JNIEnv, jlongArray, ?*jboolean) callconv(.c) [*]jlong,
    GetFloatArrayElements: *const fn (*JNIEnv, jfloatArray, ?*jboolean) callconv(.c) [*]jfloat,
    GetDoubleArrayElements: *const fn (*JNIEnv, jdoubleArray, ?*jboolean) callconv(.c) [*]jdouble,
    ReleaseBooleanArrayElements: *const fn (*JNIEnv, jbooleanArray, ?*jboolean, jint) callconv(.c) void,
    ReleaseByteArrayElements: *const fn (*JNIEnv, jbyteArray, [*]jbyte, jint) callconv(.c) void,
    ReleaseCharArrayElements: *const fn (*JNIEnv, jcharArray, [*]jchar, jint) callconv(.c) void,
    ReleaseShortArrayElements: *const fn (*JNIEnv, jshortArray, [*]jshort, jint) callconv(.c) void,
    ReleaseIntArrayElements: *const fn (*JNIEnv, jintArray, [*]jint, jint) callconv(.c) void,
    ReleaseLongArrayElements: *const fn (*JNIEnv, jlongArray, [*]jlong, jint) callconv(.c) void,
    ReleaseFloatArrayElements: *const fn (*JNIEnv, jfloatArray, [*]jfloat, jint) callconv(.c) void,
    ReleaseDoubleArrayElements: *const fn (*JNIEnv, jdoubleArray, [*]jdouble, jint) callconv(.c) void,
    GetBooleanArrayRegion: *const fn (*JNIEnv, jbooleanArray, jsize, jsize, ?*jboolean) callconv(.c) void,
    GetByteArrayRegion: *const fn (*JNIEnv, jbyteArray, jsize, jsize, [*]jbyte) callconv(.c) void,
    GetCharArrayRegion: *const fn (*JNIEnv, jcharArray, jsize, jsize, [*]jchar) callconv(.c) void,
    GetShortArrayRegion: *const fn (*JNIEnv, jshortArray, jsize, jsize, [*]jshort) callconv(.c) void,
    GetIntArrayRegion: *const fn (*JNIEnv, jintArray, jsize, jsize, [*]jint) callconv(.c) void,
    GetLongArrayRegion: *const fn (*JNIEnv, jlongArray, jsize, jsize, [*]jlong) callconv(.c) void,
    GetFloatArrayRegion: *const fn (*JNIEnv, jfloatArray, jsize, jsize, [*]jfloat) callconv(.c) void,
    GetDoubleArrayRegion: *const fn (*JNIEnv, jdoubleArray, jsize, jsize, [*]jdouble) callconv(.c) void,
    SetBooleanArrayRegion: *const fn (*JNIEnv, jbooleanArray, jsize, jsize, [*]const jboolean) callconv(.c) void,
    SetByteArrayRegion: *const fn (*JNIEnv, jbyteArray, jsize, jsize, [*]const jbyte) callconv(.c) void,
    SetCharArrayRegion: *const fn (*JNIEnv, jcharArray, jsize, jsize, [*]const jchar) callconv(.c) void,
    SetShortArrayRegion: *const fn (*JNIEnv, jshortArray, jsize, jsize, [*]const jshort) callconv(.c) void,
    SetIntArrayRegion: *const fn (*JNIEnv, jintArray, jsize, jsize, [*]const jint) callconv(.c) void,
    SetLongArrayRegion: *const fn (*JNIEnv, jlongArray, jsize, jsize, [*]const jlong) callconv(.c) void,
    SetFloatArrayRegion: *const fn (*JNIEnv, jfloatArray, jsize, jsize, [*]const jfloat) callconv(.c) void,
    SetDoubleArrayRegion: *const fn (*JNIEnv, jdoubleArray, jsize, jsize, [*]const jdouble) callconv(.c) void,
    RegisterNatives: *const fn (*JNIEnv, jclass, [*]const JNINativeMethod, jint) callconv(.c) jint,
    UnregisterNatives: *const fn (*JNIEnv, jclass) callconv(.c) jint,
    MonitorEnter: *const fn (*JNIEnv, jobject) callconv(.c) jint,
    MonitorExit: *const fn (*JNIEnv, jobject) callconv(.c) jint,
    GetJavaVM: *const fn (*JNIEnv, *?*JavaVM) callconv(.c) jint,
    GetStringRegion: *const fn (*JNIEnv, jstring, jsize, jsize, [*]jchar) callconv(.c) void,
    GetStringUTFRegion: *const fn (*JNIEnv, jstring, jsize, jsize, [*]u8) callconv(.c) void,
    GetPrimitiveArrayCritical: *const fn (*JNIEnv, jarray, ?*jboolean) callconv(.c) ?*anyopaque,
    ReleasePrimitiveArrayCritical: *const fn (*JNIEnv, jarray, ?*anyopaque, jint) callconv(.c) void,
    GetStringCritical: *const fn (*JNIEnv, jstring, ?*jboolean) callconv(.c) [*]const jchar,
    ReleaseStringCritical: *const fn (*JNIEnv, jstring, [*]const jchar) callconv(.c) void,
    NewWeakGlobalRef: *const fn (*JNIEnv, jobject) callconv(.c) jweak,
    DeleteWeakGlobalRef: *const fn (*JNIEnv, jweak) callconv(.c) void,
    ExceptionCheck: *const fn (*JNIEnv) callconv(.c) jboolean,
    NewDirectByteBuffer: *const fn (*JNIEnv, ?*anyopaque, jlong) callconv(.c) jobject,
    GetDirectBufferAddress: *const fn (*JNIEnv, jobject) callconv(.c) ?*anyopaque,
    GetDirectBufferCapacity: *const fn (*JNIEnv, jobject) callconv(.c) jlong,
    GetObjectRefType: *const fn (*JNIEnv, jobject) callconv(.c) jobjectRefType,
    GetModule: *const fn (*JNIEnv, jclass) callconv(.c) jobject,
};

pub const JNIInvokeInterface = extern struct {
    reserved0: ?*anyopaque,
    reserved1: ?*anyopaque,
    reserved2: ?*anyopaque,
    DestroyJavaVM: *const fn (*JavaVM) callconv(.c) jint,
    AttachCurrentThread: *const fn (*JavaVM, *?*anyopaque, ?*anyopaque) callconv(.c) jint,
    DetachCurrentThread: *const fn (*JavaVM) callconv(.c) jint,
    GetEnv: *const fn (*JavaVM, *?*anyopaque, jint) callconv(.c) jint,
    AttachCurrentThreadAsDaemon: *const fn (*JavaVM, *?*anyopaque, ?*anyopaque) callconv(.c) jint,
};
