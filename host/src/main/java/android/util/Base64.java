package android.util;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * android.util.Base64 implemented on top of java.util.Base64, honouring the
 * Android flag semantics (line wrapping, padding, URL-safe alphabet, leniency
 * towards whitespace when decoding).
 */
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {
    }

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.US_ASCII), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        // Android's decoder skips whitespace and tolerates missing padding.
        StringBuilder sb = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            char c = (char) (input[i] & 0xff);
            if (c == '\n' || c == '\r' || c == ' ' || c == '\t') {
                continue;
            }
            if (c == '=') {
                break;
            }
            sb.append(c);
        }
        int rem = sb.length() % 4;
        if (rem == 1) {
            throw new IllegalArgumentException("bad base-64");
        }
        while (sb.length() % 4 != 0) {
            sb.append('=');
        }
        java.util.Base64.Decoder decoder = (flags & URL_SAFE) != 0
                ? java.util.Base64.getUrlDecoder()
                : java.util.Base64.getDecoder();
        try {
            return decoder.decode(sb.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0
                ? java.util.Base64.getUrlEncoder()
                : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) {
            encoder = encoder.withoutPadding();
        }
        byte[] encoded = encoder.encode(Arrays.copyOfRange(input, offset, offset + len));
        if ((flags & NO_WRAP) != 0) {
            return encoded;
        }
        // Android inserts a line separator every 76 output characters and after the last line.
        byte[] sep = (flags & CRLF) != 0 ? new byte[]{'\r', '\n'} : new byte[]{'\n'};
        int lines = (encoded.length + 75) / 76;
        byte[] out = new byte[encoded.length + lines * sep.length];
        int o = 0;
        for (int i = 0; i < encoded.length; i += 76) {
            int n = Math.min(76, encoded.length - i);
            System.arraycopy(encoded, i, out, o, n);
            o += n;
            System.arraycopy(sep, 0, out, o, sep.length);
            o += sep.length;
        }
        return out;
    }
}
