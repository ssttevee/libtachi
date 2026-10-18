package android.webkit;

import dev.tachi.host.TachiRuntime;
import eu.kanade.tachiyomi.network.PersistentCookieJar;

/** android.webkit.CookieManager backed by the shared OkHttp cookie jar. */
public class CookieManager {
    private static final CookieManager INSTANCE = new CookieManager();

    public static CookieManager getInstance() {
        return INSTANCE;
    }

    private PersistentCookieJar jar() {
        return TachiRuntime.INSTANCE.getNetwork().getCookieJar();
    }

    public void setAcceptCookie(boolean accept) {
    }

    public boolean acceptCookie() {
        return true;
    }

    public void setCookie(String url, String value) {
        jar().setCookie(url, value);
    }

    public void setCookie(String url, String value, ValueCallback<Boolean> callback) {
        setCookie(url, value);
        if (callback != null) {
            callback.onReceiveValue(true);
        }
    }

    public String getCookie(String url) {
        return jar().getCookieHeader(url);
    }

    public boolean hasCookies() {
        return jar().hasCookies();
    }

    public void removeAllCookies(ValueCallback<Boolean> callback) {
        jar().removeAll();
        if (callback != null) {
            callback.onReceiveValue(true);
        }
    }

    public void removeAllCookie() {
        jar().removeAll();
    }

    public void removeSessionCookies(ValueCallback<Boolean> callback) {
        if (callback != null) {
            callback.onReceiveValue(false);
        }
    }

    public void removeSessionCookie() {
    }

    public void removeExpiredCookie() {
    }

    public void flush() {
    }

    public void setAcceptThirdPartyCookies(WebView webview, boolean accept) {
    }
}
