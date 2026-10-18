package androidx.preference;

import android.content.Context;

public final class PreferenceScreen extends PreferenceGroup {
    public PreferenceScreen(Context context) {
        super(context);
    }

    public PreferenceScreen(Context context, PreferenceManager manager) {
        super(context);
        setPreferenceManager(manager);
    }
}
