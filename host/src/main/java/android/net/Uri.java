package android.net;

import android.os.Parcel;
import android.os.Parcelable;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * A lenient, immutable URI reference modelled on android.net.Uri.
 *
 * Unlike java.net.URI this never throws on malformed input: the string is
 * split into scheme / authority / path / query / fragment on a best-effort
 * basis, exactly as extensions expect from Android.
 */
public class Uri implements Comparable<Uri>, Parcelable {
    public static final Uri EMPTY = new Uri(null, null, "", null, null, false);

    private static final String UNRESERVED = "_-!.~'()*";

    private final String scheme;
    private final String encodedAuthority;
    private final String encodedPath;
    private final String encodedQuery;
    private final String encodedFragment;
    private final boolean opaque;

    private Uri(String scheme, String encodedAuthority, String encodedPath, String encodedQuery,
                String encodedFragment, boolean opaque) {
        this.scheme = scheme;
        this.encodedAuthority = encodedAuthority;
        this.encodedPath = encodedPath;
        this.encodedQuery = encodedQuery;
        this.encodedFragment = encodedFragment;
        this.opaque = opaque;
    }

    public static Uri parse(String uriString) {
        if (uriString == null) {
            throw new NullPointerException("uriString");
        }
        String s = uriString;
        String scheme = null;
        String fragment = null;
        int hash = s.indexOf('#');
        if (hash >= 0) {
            fragment = s.substring(hash + 1);
            s = s.substring(0, hash);
        }
        int colon = s.indexOf(':');
        int slash = s.indexOf('/');
        int question = s.indexOf('?');
        if (colon > 0 && (slash < 0 || colon < slash) && (question < 0 || colon < question)) {
            scheme = s.substring(0, colon);
            s = s.substring(colon + 1);
        }
        boolean opaque = scheme != null && !s.startsWith("/");
        if (opaque) {
            // scheme:opaque-part[#fragment]
            return new Uri(scheme, null, s, null, fragment, true);
        }
        String authority = null;
        if (s.startsWith("//")) {
            int end = s.length();
            for (int i = 2; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '/' || c == '?') {
                    end = i;
                    break;
                }
            }
            authority = s.substring(2, end);
            s = s.substring(end);
        }
        String query = null;
        int q = s.indexOf('?');
        if (q >= 0) {
            query = s.substring(q + 1);
            s = s.substring(0, q);
        }
        return new Uri(scheme, authority, s, query, fragment, false);
    }

    public static Uri fromFile(File file) {
        return new Builder().scheme("file").authority("").path(file.getAbsolutePath()).build();
    }

    public static Uri fromParts(String scheme, String ssp, String fragment) {
        return new Uri(scheme, null, encode(ssp), null, encode(fragment), true);
    }

    public static Uri withAppendedPath(Uri baseUri, String pathSegment) {
        return baseUri.buildUpon().appendEncodedPath(pathSegment).build();
    }

    public String getScheme() {
        return scheme;
    }

    public boolean isAbsolute() {
        return scheme != null;
    }

    public boolean isRelative() {
        return scheme == null;
    }

    public boolean isOpaque() {
        return opaque;
    }

    public boolean isHierarchical() {
        return !opaque;
    }

    public String getSchemeSpecificPart() {
        return decode(getEncodedSchemeSpecificPart());
    }

    public String getEncodedSchemeSpecificPart() {
        if (opaque) {
            return encodedPath;
        }
        StringBuilder sb = new StringBuilder();
        if (encodedAuthority != null) {
            sb.append("//").append(encodedAuthority);
        }
        sb.append(encodedPath);
        if (encodedQuery != null) {
            sb.append('?').append(encodedQuery);
        }
        return sb.toString();
    }

    public String getAuthority() {
        return decode(encodedAuthority);
    }

    public String getEncodedAuthority() {
        return encodedAuthority;
    }

    public String getUserInfo() {
        if (encodedAuthority == null) {
            return null;
        }
        int at = encodedAuthority.lastIndexOf('@');
        return at < 0 ? null : decode(encodedAuthority.substring(0, at));
    }

    public String getEncodedUserInfo() {
        if (encodedAuthority == null) {
            return null;
        }
        int at = encodedAuthority.lastIndexOf('@');
        return at < 0 ? null : encodedAuthority.substring(0, at);
    }

    public String getHost() {
        if (encodedAuthority == null) {
            return null;
        }
        String hostPort = encodedAuthority;
        int at = hostPort.lastIndexOf('@');
        if (at >= 0) {
            hostPort = hostPort.substring(at + 1);
        }
        // IPv6 literal
        if (hostPort.startsWith("[")) {
            int close = hostPort.indexOf(']');
            return close < 0 ? hostPort : hostPort.substring(0, close + 1);
        }
        int colon = hostPort.indexOf(':');
        return decode(colon < 0 ? hostPort : hostPort.substring(0, colon));
    }

    public int getPort() {
        if (encodedAuthority == null) {
            return -1;
        }
        String hostPort = encodedAuthority;
        int at = hostPort.lastIndexOf('@');
        if (at >= 0) {
            hostPort = hostPort.substring(at + 1);
        }
        int colon = hostPort.lastIndexOf(':');
        int bracket = hostPort.lastIndexOf(']');
        if (colon < 0 || colon < bracket) {
            return -1;
        }
        try {
            return Integer.parseInt(hostPort.substring(colon + 1));
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    public String getPath() {
        return opaque ? null : decode(encodedPath);
    }

    public String getEncodedPath() {
        return opaque ? null : encodedPath;
    }

    public List<String> getPathSegments() {
        if (opaque || encodedPath == null || encodedPath.isEmpty()) {
            return Collections.emptyList();
        }
        List<String> out = new ArrayList<>();
        for (String seg : encodedPath.split("/")) {
            if (!seg.isEmpty()) {
                out.add(decode(seg));
            }
        }
        return Collections.unmodifiableList(out);
    }

    public String getLastPathSegment() {
        List<String> segs = getPathSegments();
        return segs.isEmpty() ? null : segs.get(segs.size() - 1);
    }

    public String getQuery() {
        return decode(encodedQuery);
    }

    public String getEncodedQuery() {
        return encodedQuery;
    }

    public String getFragment() {
        return decode(encodedFragment);
    }

    public String getEncodedFragment() {
        return encodedFragment;
    }

    public Set<String> getQueryParameterNames() {
        if (encodedQuery == null) {
            return Collections.emptySet();
        }
        Set<String> names = new LinkedHashSet<>();
        for (String pair : encodedQuery.split("&")) {
            if (pair.isEmpty()) {
                continue;
            }
            int eq = pair.indexOf('=');
            names.add(decode(eq < 0 ? pair : pair.substring(0, eq)));
        }
        return Collections.unmodifiableSet(names);
    }

    public List<String> getQueryParameters(String key) {
        if (key == null) {
            throw new NullPointerException("key");
        }
        if (encodedQuery == null) {
            return Collections.emptyList();
        }
        String encodedKey = encode(key, null);
        List<String> values = new ArrayList<>();
        for (String pair : encodedQuery.split("&")) {
            int eq = pair.indexOf('=');
            String k = eq < 0 ? pair : pair.substring(0, eq);
            if (k.equals(encodedKey) || decode(k).equals(key)) {
                values.add(eq < 0 ? "" : decodePlus(pair.substring(eq + 1)));
            }
        }
        return Collections.unmodifiableList(values);
    }

    public String getQueryParameter(String key) {
        List<String> values = getQueryParameters(key);
        return values.isEmpty() ? null : values.get(0);
    }

    public boolean getBooleanQueryParameter(String key, boolean defaultValue) {
        String flag = getQueryParameter(key);
        if (flag == null) {
            return defaultValue;
        }
        flag = flag.toLowerCase();
        return !("false".equals(flag) || "0".equals(flag));
    }

    public Uri normalizeScheme() {
        if (scheme == null) {
            return this;
        }
        String lower = scheme.toLowerCase();
        return lower.equals(scheme) ? this : buildUpon().scheme(lower).build();
    }

    public Builder buildUpon() {
        Builder b = new Builder().scheme(scheme);
        if (opaque) {
            return b.encodedOpaquePart(encodedPath).encodedFragment(encodedFragment);
        }
        return b.encodedAuthority(encodedAuthority)
                .encodedPath(encodedPath)
                .encodedQuery(encodedQuery)
                .encodedFragment(encodedFragment);
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder();
        if (scheme != null) {
            sb.append(scheme).append(':');
        }
        sb.append(getEncodedSchemeSpecificPart());
        if (encodedFragment != null) {
            sb.append('#').append(encodedFragment);
        }
        return sb.toString();
    }

    @Override
    public boolean equals(Object o) {
        return o instanceof Uri && toString().equals(o.toString());
    }

    @Override
    public int hashCode() {
        return toString().hashCode();
    }

    @Override
    public int compareTo(Uri other) {
        return toString().compareTo(other.toString());
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel dest, int flags) {
    }

    // ---- encoding helpers -------------------------------------------------

    public static String encode(String s) {
        return encode(s, null);
    }

    public static String encode(String s, String allow) {
        if (s == null) {
            return null;
        }
        StringBuilder sb = null;
        int len = s.length();
        int i = 0;
        while (i < len) {
            int start = i;
            while (i < len && isAllowed(s.charAt(i), allow)) {
                i++;
            }
            if (i == len) {
                if (start == 0) {
                    return s;
                }
                sb.append(s, start, len);
                return sb.toString();
            }
            if (sb == null) {
                sb = new StringBuilder(len * 2);
            }
            sb.append(s, start, i);
            start = i;
            while (i < len && !isAllowed(s.charAt(i), allow)) {
                i++;
            }
            byte[] bytes = s.substring(start, i).getBytes(StandardCharsets.UTF_8);
            for (byte b : bytes) {
                sb.append('%');
                sb.append("0123456789ABCDEF".charAt((b >> 4) & 0xf));
                sb.append("0123456789ABCDEF".charAt(b & 0xf));
            }
        }
        return sb == null ? s : sb.toString();
    }

    private static boolean isAllowed(char c, String allow) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                || UNRESERVED.indexOf(c) != -1 || (allow != null && allow.indexOf(c) != -1);
    }

    public static String decode(String s) {
        if (s == null) {
            return null;
        }
        if (s.indexOf('%') < 0) {
            return s;
        }
        byte[] out = new byte[s.length()];
        int o = 0;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '%' && i + 2 < s.length() + 0 && i + 2 <= s.length() - 1) {
                int hi = Character.digit(s.charAt(i + 1), 16);
                int lo = Character.digit(s.charAt(i + 2), 16);
                if (hi >= 0 && lo >= 0) {
                    out[o++] = (byte) ((hi << 4) | lo);
                    i += 2;
                    continue;
                }
            }
            byte[] b = String.valueOf(c).getBytes(StandardCharsets.UTF_8);
            if (o + b.length > out.length) {
                byte[] bigger = new byte[out.length * 2 + b.length];
                System.arraycopy(out, 0, bigger, 0, o);
                out = bigger;
            }
            System.arraycopy(b, 0, out, o, b.length);
            o += b.length;
        }
        return new String(out, 0, o, StandardCharsets.UTF_8);
    }

    private static String decodePlus(String s) {
        return decode(s.replace('+', ' '));
    }

    // ---- builder -----------------------------------------------------------

    public static final class Builder {
        private String scheme;
        private String encodedAuthority;
        private String encodedPath = "";
        private String encodedQuery;
        private String encodedFragment;
        private String encodedOpaquePart;

        public Builder scheme(String scheme) {
            this.scheme = scheme;
            return this;
        }

        public Builder opaquePart(String opaquePart) {
            return encodedOpaquePart(encode(opaquePart));
        }

        public Builder encodedOpaquePart(String opaquePart) {
            this.encodedOpaquePart = opaquePart;
            return this;
        }

        public Builder authority(String authority) {
            return encodedAuthority(encode(authority));
        }

        public Builder encodedAuthority(String authority) {
            this.encodedOpaquePart = null;
            this.encodedAuthority = authority;
            return this;
        }

        public Builder path(String path) {
            return encodedPath(encode(path, "/"));
        }

        public Builder encodedPath(String path) {
            this.encodedOpaquePart = null;
            this.encodedPath = path == null ? "" : path;
            return this;
        }

        public Builder appendPath(String newSegment) {
            return appendEncodedPath(encode(newSegment, null));
        }

        public Builder appendEncodedPath(String newSegment) {
            this.encodedOpaquePart = null;
            if (encodedPath == null || encodedPath.isEmpty()) {
                encodedPath = "/" + newSegment;
            } else if (encodedPath.endsWith("/")) {
                encodedPath = encodedPath + newSegment;
            } else {
                encodedPath = encodedPath + "/" + newSegment;
            }
            return this;
        }

        public Builder query(String query) {
            return encodedQuery(encode(query, "=&"));
        }

        public Builder encodedQuery(String query) {
            this.encodedOpaquePart = null;
            this.encodedQuery = query;
            return this;
        }

        public Builder appendQueryParameter(String key, String value) {
            this.encodedOpaquePart = null;
            String pair = encode(key, null) + "=" + encode(value, null);
            encodedQuery = encodedQuery == null || encodedQuery.isEmpty() ? pair : encodedQuery + "&" + pair;
            return this;
        }

        public Builder clearQuery() {
            return encodedQuery(null);
        }

        public Builder fragment(String fragment) {
            return encodedFragment(encode(fragment));
        }

        public Builder encodedFragment(String fragment) {
            this.encodedFragment = fragment;
            return this;
        }

        public Uri build() {
            if (encodedOpaquePart != null) {
                return new Uri(scheme, null, encodedOpaquePart, null, encodedFragment, true);
            }
            String path = encodedPath;
            if (encodedAuthority != null && path != null && !path.isEmpty() && !path.startsWith("/")) {
                path = "/" + path;
            }
            return new Uri(scheme, encodedAuthority, path, encodedQuery, encodedFragment, false);
        }

        @Override
        public String toString() {
            return build().toString();
        }
    }
}
