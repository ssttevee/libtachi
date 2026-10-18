package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

/** Associates a PreferenceScreen with the SharedPreferences its values persist to. */
public class PreferenceManager {
    private final Context context;
    private SharedPreferences sharedPreferences;

    public PreferenceManager(Context context) {
        this.context = context;
    }

    public Context getContext() {
        return context;
    }

    public SharedPreferences getSharedPreferences() {
        return sharedPreferences;
    }

    public void setSharedPreferences(SharedPreferences prefs) {
        this.sharedPreferences = prefs;
    }

    public static SharedPreferences getDefaultSharedPreferences(Context context) {
        return context.getSharedPreferences(context.getPackageName() + "_preferences", Context.MODE_PRIVATE);
    }
}
