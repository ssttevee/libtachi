package android.content;

import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.content.res.Resources;
import android.os.Looper;

import java.io.File;

/** Proxying implementation of Context that delegates to another Context. */
public class ContextWrapper extends Context {
    private Context mBase;

    public ContextWrapper(Context base) {
        mBase = base;
    }

    protected void attachBaseContext(Context base) {
        if (mBase != null) {
            throw new IllegalStateException("Base context already set");
        }
        mBase = base;
    }

    public Context getBaseContext() {
        return mBase;
    }

    @Override
    public SharedPreferences getSharedPreferences(String name, int mode) {
        return mBase.getSharedPreferences(name, mode);
    }

    @Override
    public File getCacheDir() {
        return mBase.getCacheDir();
    }

    @Override
    public File getFilesDir() {
        return mBase.getFilesDir();
    }

    @Override
    public File getDataDir() {
        return mBase.getDataDir();
    }

    @Override
    public File getCodeCacheDir() {
        return mBase.getCodeCacheDir();
    }

    @Override
    public File getNoBackupFilesDir() {
        return mBase.getNoBackupFilesDir();
    }

    @Override
    public File getExternalCacheDir() {
        return mBase.getExternalCacheDir();
    }

    @Override
    public File getExternalFilesDir(String type) {
        return mBase.getExternalFilesDir(type);
    }

    @Override
    public String getPackageName() {
        return mBase.getPackageName();
    }

    @Override
    public Context getApplicationContext() {
        return mBase.getApplicationContext();
    }

    @Override
    public ClassLoader getClassLoader() {
        return mBase.getClassLoader();
    }

    @Override
    public Object getSystemService(String name) {
        return mBase.getSystemService(name);
    }

    @Override
    public Resources getResources() {
        return mBase.getResources();
    }

    @Override
    public AssetManager getAssets() {
        return mBase.getAssets();
    }

    @Override
    public PackageManager getPackageManager() {
        return mBase.getPackageManager();
    }

    @Override
    public ContentResolver getContentResolver() {
        return mBase.getContentResolver();
    }

    @Override
    public Looper getMainLooper() {
        return mBase.getMainLooper();
    }

    @Override
    public String getString(int resId) {
        return mBase.getString(resId);
    }

    @Override
    public String getString(int resId, Object... formatArgs) {
        return mBase.getString(resId, formatArgs);
    }

    @Override
    public void startActivity(Intent intent) {
        mBase.startActivity(intent);
    }
}
