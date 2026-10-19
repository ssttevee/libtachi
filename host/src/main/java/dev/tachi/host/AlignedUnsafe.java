package dev.tachi.host;

import sun.misc.Unsafe;

/** Little-endian word access for Aircompressor on strict-alignment ARM Zero.
 * Aligned accesses retain the upstream fast path. Unaligned byte-array accesses
 * use Java indexing; other bases use single-byte Unsafe operations, never words.
 */
public final class AlignedUnsafe {
    private AlignedUnsafe() {}
    private static byte getByte(Unsafe u, Object base, long offset) {
        if (base instanceof byte[] bytes) return bytes[Math.toIntExact(offset - Unsafe.ARRAY_BYTE_BASE_OFFSET)];
        return u.getByte(base, offset);
    }
    private static void putByte(Unsafe u, Object base, long offset, byte value) {
        if (base instanceof byte[] bytes) bytes[Math.toIntExact(offset - Unsafe.ARRAY_BYTE_BASE_OFFSET)] = value;
        else u.putByte(base, offset, value);
    }
    public static short getShort(Unsafe u, Object base, long offset) {
        if ((offset & 1) == 0) return u.getShort(base, offset);
        return (short)((getByte(u, base, offset) & 255) | ((getByte(u, base, offset + 1) & 255) << 8));
    }
    public static int getInt(Unsafe u, Object base, long offset) {
        if ((offset & 3) == 0) return u.getInt(base, offset);
        return (getShort(u, base, offset) & 65535) | ((getShort(u, base, offset + 2) & 65535) << 16);
    }
    public static long getLong(Unsafe u, Object base, long offset) {
        if ((offset & 7) == 0) return u.getLong(base, offset);
        return (getInt(u, base, offset) & 0xffffffffL) | ((getInt(u, base, offset + 4) & 0xffffffffL) << 32);
    }
    public static void putShort(Unsafe u, Object base, long offset, short value) {
        if ((offset & 1) == 0) u.putShort(base, offset, value);
        else {
            putByte(u, base, offset, (byte)value);
            putByte(u, base, offset + 1, (byte)(value >>> 8));
        }
    }
    public static void putInt(Unsafe u, Object base, long offset, int value) {
        if ((offset & 3) == 0) u.putInt(base, offset, value);
        else {
            putShort(u, base, offset, (short)value);
            putShort(u, base, offset + 2, (short)(value >>> 16));
        }
    }
    public static void putLong(Unsafe u, Object base, long offset, long value) {
        if ((offset & 7) == 0) u.putLong(base, offset, value);
        else {
            putInt(u, base, offset, (int)value);
            putInt(u, base, offset + 4, (int)(value >>> 32));
        }
    }
}
