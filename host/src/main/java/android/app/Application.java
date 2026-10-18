package android.app;

import android.content.Context;
import android.content.ContextWrapper;

/**
 * Minimal replacement for android.app.Application. The host runtime creates one
 * instance and attaches a Context that points at the configured data directories.
 */
public class Application extends ContextWrapper {
    public interface ActivityLifecycleCallbacks {
    }

    public Application() {
        super(null);
    }

    /** Called by the host runtime; mirrors what ActivityThread does on Android. */
    public final void attach(Context base) {
        attachBaseContext(base);
    }

    public void onCreate() {
    }

    public void onTerminate() {
    }

    public void onLowMemory() {
    }

    public void onTrimMemory(int level) {
    }

    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
    }

    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
    }

    @Override
    public Context getApplicationContext() {
        return this;
    }
}
