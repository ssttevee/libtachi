# Source-built zstd JNI decoder

`build.zig.zon` pins the unmodified upstream **source** release as the lazy
`zstd` dependency:
https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz

Zig verifies the package hash on fetch and caches it; no native binary is
downloaded. The archive contains the BSD/GPL dual license; the bundled library
is distributed under its BSD option (`licenses/zstd-LICENSE.txt`).

`zig build zstd -Dtarget=<triple> -Dcpu=<cpu>` compiles upstream
`lib/common/*.c`, `lib/decompress/*.c` and `zstd_jni.c` into
`<prefix>/lib/libpocketmanga-zstd.so` and copies the license to
`<prefix>/share/licenses/zstd-LICENSE.txt`. Legacy formats and assembly are off
and word access goes through memcpy. For the PocketBook Verse:

```sh
zig build zstd -Dtarget=arm-linux-gnueabi.2.17 -Dcpu=cortex_a7+strict_align -Doptimize=ReleaseFast
```

Dependent builds use the named lazy paths `pocketmanga-zstd` and
`zstd-license` instead, so the library is built for whatever target they pass
and cached with the rest of their build. `jni.h` comes from a JDK, chosen with
`-Djdk=<path>` or `JAVA_HOME`; the small `include/jni_md.h` supplies the Linux
JNI scalar ABI, so no ARM sysroot is needed.

The decoder bounds window memory to 64 MiB and releases its context on close,
with a Cleaner as a last resort. The JVM stream uses a 64 KiB input buffer.

The host retains OkHttp 5.5.0's exact `okhttp3.zstd.Zstd` object ABI. Square's
zstd-kmp JVM loader was inspected at:
https://github.com/square/zstd-kmp/blob/main/zstd-kmp/src/jvmMain/kotlin/com/squareup/zstd/JvmZstd.kt
It unconditionally extracts a jar resource via `Files.createTempFile` and has
no bundled-path override, so it cannot meet the worker's loading constraint.
The minimal JNI bridge avoids that extraction. On device, `System.load` uses
`java.home/../lib/libpocketmanga-zstd.so`, i.e. the application's `runtime/lib/`.
`-Dtachi.zstd.library=...` is an explicit desktop test override.

`./gradlew testZstd --offline` runs `zig build zstd` for the desktop and
exercises streaming, one-byte input, concatenated frames, truncated input,
corrupt checksums and source closure. The app's firmware fixtures serve real
checksummed zstd responses through the original CompressionInterceptor, then
inspect `/proc/self/maps` for the bundled decoder path under ARM Zero.
