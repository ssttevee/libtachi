package androidx.preference;

import android.content.Context;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public abstract class PreferenceGroup extends Preference {
    private final List<Preference> preferences = new ArrayList<>();

    public PreferenceGroup(Context context) {
        super(context);
    }

    public boolean addPreference(Preference preference) {
        if (preferences.contains(preference)) {
            return true;
        }
        preference.setPreferenceManager(getPreferenceManager());
        if (preference.getOrder() == Integer.MAX_VALUE) {
            preference.setOrder(preferences.size());
        }
        preferences.add(preference);
        return true;
    }

    public boolean removePreference(Preference preference) {
        return preferences.remove(preference);
    }

    public void removeAll() {
        preferences.clear();
    }

    public int getPreferenceCount() {
        return preferences.size();
    }

    public Preference getPreference(int index) {
        return preferences.get(index);
    }

    public Preference findPreference(CharSequence key) {
        if (key == null) {
            return null;
        }
        for (Preference p : preferences) {
            if (key.toString().equals(p.getKey())) {
                return p;
            }
            if (p instanceof PreferenceGroup) {
                Preference nested = ((PreferenceGroup) p).findPreference(key);
                if (nested != null) {
                    return nested;
                }
            }
        }
        return null;
    }

    /** All preferences in insertion order, descending into nested groups. */
    public List<Preference> getPreferences() {
        return Collections.unmodifiableList(preferences);
    }

    @Override
    void setPreferenceManager(PreferenceManager manager) {
        super.setPreferenceManager(manager);
        for (Preference p : preferences) {
            p.setPreferenceManager(manager);
        }
    }
}
