#include <jni.h>
#include <stdint.h>
#include <zstd.h>

static void fail(JNIEnv *env, const char *type, const char *message) {
    jclass cls = (*env)->FindClass(env, type);
    if (cls) (*env)->ThrowNew(env, cls, message);
}
JNIEXPORT jlong JNICALL Java_dev_tachi_host_NativeZstdInputStream_create(JNIEnv *env, jclass cls) {
    (void)cls;
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    if (!ctx) { fail(env, "java/lang/OutOfMemoryError", "ZSTD_createDCtx"); return 0; }
    // Bound decoder window memory in the 128 MiB worker, including hostile frames.
    size_t result = ZSTD_DCtx_setParameter(ctx, ZSTD_d_windowLogMax, 26);
    if (ZSTD_isError(result)) {
        ZSTD_freeDCtx(ctx);
        fail(env, "java/io/IOException", ZSTD_getErrorName(result));
        return 0;
    }
    return (jlong)(intptr_t)ctx;
}
JNIEXPORT void JNICALL Java_dev_tachi_host_NativeZstdInputStream_inflate(JNIEnv *env, jclass cls,
    jlong handle, jbyteArray input, jint offset, jint count,
    jbyteArray output, jint outputOffset, jint outputCount, jintArray progress) {
    (void)cls;
    // ArrayElements (not Critical) permits allocation by the streaming decoder.
    jbyte *in = (*env)->GetByteArrayElements(env, input, NULL);
    if (!in) return;
    jbyte *out = (*env)->GetByteArrayElements(env, output, NULL);
    if (!out) { (*env)->ReleaseByteArrayElements(env, input, in, JNI_ABORT); return; }
    ZSTD_inBuffer src = {in + offset, (size_t)count, 0};
    ZSTD_outBuffer dst = {out + outputOffset, (size_t)outputCount, 0};
    size_t result = ZSTD_decompressStream((ZSTD_DCtx *)(intptr_t)handle, &dst, &src);
    (*env)->ReleaseByteArrayElements(env, output, out, 0);
    (*env)->ReleaseByteArrayElements(env, input, in, JNI_ABORT);
    if (ZSTD_isError(result)) { fail(env, "java/io/IOException", ZSTD_getErrorName(result)); return; }
    jint values[3] = {(jint)src.pos, (jint)dst.pos, result == 0 ? 0 : 1};
    (*env)->SetIntArrayRegion(env, progress, 0, 3, values);
}
JNIEXPORT void JNICALL Java_dev_tachi_host_NativeZstdInputStream_destroy(JNIEnv *env, jclass cls, jlong handle) {
    (void)env; (void)cls;
    ZSTD_freeDCtx((ZSTD_DCtx *)(intptr_t)handle);
}
