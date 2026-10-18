package android.content;

import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.content.res.Resources;
import android.os.Looper;

import java.io.File;

/**
 * Minimal replacement for android.content.Context.
 *
 * The real class has ~300 abstract methods; extensions only ever reach a
 * handful (preferences, cache/files dirs, package name). Methods are kept
 * non-final and the names/descriptors match AOSP so extension bytecode links.
 */
public abstract class Context {
    public static final int MODE_PRIVATE = 0x0000;
    public static final int MODE_WORLD_READABLE = 0x0001;
    public static final int MODE_WORLD_WRITEABLE = 0x0002;
    public static final int MODE_APPEND = 0x8000;
    public static final int MODE_MULTI_PROCESS = 0x0004;

    public static final String CONNECTIVITY_SERVICE = "connectivity";
    public static final String POWER_SERVICE = "power";
    public static final String CLIPBOARD_SERVICE = "clipboard";
    public static final String NOTIFICATION_SERVICE = "notification";
    public static final String ACTIVITY_SERVICE = "activity";
    public static final String DOWNLOAD_SERVICE = "download";

    public abstract SharedPreferences getSharedPreferences(String name, int mode);

    public abstract File getCacheDir();

    public abstract File getFilesDir();

    public abstract File getDataDir();

    public File getCodeCacheDir() {
        return getCacheDir();
    }

    public File getNoBackupFilesDir() {
        return getFilesDir();
    }

    public File getExternalCacheDir() {
        return getCacheDir();
    }

    public File getExternalFilesDir(String type) {
        File dir = type == null ? getFilesDir() : new File(getFilesDir(), type);
        dir.mkdirs();
        return dir;
    }

    public abstract String getPackageName();

    public abstract Context getApplicationContext();

    public ClassLoader getClassLoader() {
        return getClass().getClassLoader();
    }

    public Object getSystemService(String name) {
        return null;
    }

    public String getSystemServiceName(Class<?> serviceClass) {
        return null;
    }

    public Resources getResources() {
        return null;
    }

    public AssetManager getAssets() {
        return null;
    }

    public PackageManager getPackageManager() {
        return null;
    }

    public ContentResolver getContentResolver() {
        return null;
    }

    public Looper getMainLooper() {
        return Looper.getMainLooper();
    }

    public String getString(int resId) {
        return "";
    }

    public String getString(int resId, Object... formatArgs) {
        return "";
    }

    public CharSequence getText(int resId) {
        return "";
    }

    public void startActivity(Intent intent) {
        throw new ActivityNotFoundException("Activities are not available in the tachi host runtime");
    }

    public boolean deleteSharedPreferences(String name) {
        return false;
    }

    public File getDatabasePath(String name) {
        return new File(getDataDir(), "databases/" + name);
    }

    public boolean deleteFile(String name) {
        return new File(getFilesDir(), name).delete();
    }

    public File getFileStreamPath(String name) {
        return new File(getFilesDir(), name);
    }
}
