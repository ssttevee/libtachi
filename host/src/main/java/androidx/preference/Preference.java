package androidx.preference;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Minimal androidx.preference.Preference: a bag of attributes that extensions
 * fill in from setupPreferenceScreen(). The host serialises these for the
 * embedding application's settings UI and writes values back through
 * {@link #callChangeListener(Object)}.
 */
public class Preference implements Comparable<Preference> {
    public interface OnPreferenceChangeListener {
        boolean onPreferenceChange(Preference preference, Object newValue);
    }

    public interface OnPreferenceClickListener {
        boolean onPreferenceClick(Preference preference);
    }

    public interface SummaryProvider<T extends Preference> {
        CharSequence provideSummary(T preference);
    }

    private final Context context;
    private String key;
    private CharSequence title;
    private CharSequence summary;
    private Object defaultValue;
    private boolean enabled = true;
    private boolean visible = true;
    private boolean persistent = true;
    private boolean selectable = true;
    private boolean iconSpaceReserved = true;
    private boolean singleLineTitle = true;
    private int order = Integer.MAX_VALUE;
    private String dependencyKey;
    private OnPreferenceChangeListener onPreferenceChangeListener;
    private OnPreferenceClickListener onPreferenceClickListener;
    private SummaryProvider<?> summaryProvider;
    private PreferenceManager preferenceManager;

    public Preference(Context context) {
        this.context = context;
    }

    public Context getContext() {
        return context;
    }

    public String getKey() {
        return key;
    }

    public void setKey(String key) {
        this.key = key;
    }

    public boolean hasKey() {
        return key != null && !key.isEmpty();
    }

    public CharSequence getTitle() {
        return title;
    }

    public void setTitle(CharSequence title) {
        this.title = title;
    }

    public void setTitle(int titleResId) {
    }

    public CharSequence getSummary() {
        if (summaryProvider != null) {
            @SuppressWarnings("unchecked")
            SummaryProvider<Preference> p = (SummaryProvider<Preference>) summaryProvider;
            return p.provideSummary(this);
        }
        return summary;
    }

    public void setSummary(CharSequence summary) {
        this.summary = summary;
    }

    public void setSummary(int summaryResId) {
    }

    public Object getDefaultValue() {
        return defaultValue;
    }

    public void setDefaultValue(Object defaultValue) {
        this.defaultValue = defaultValue;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean isVisible() {
        return visible;
    }

    public void setVisible(boolean visible) {
        this.visible = visible;
    }

    public boolean isPersistent() {
        return persistent;
    }

    public void setPersistent(boolean persistent) {
        this.persistent = persistent;
    }

    public boolean isSelectable() {
        return selectable;
    }

    public void setSelectable(boolean selectable) {
        this.selectable = selectable;
    }

    public void setIconSpaceReserved(boolean reserved) {
        this.iconSpaceReserved = reserved;
    }

    public boolean isIconSpaceReserved() {
        return iconSpaceReserved;
    }

    public void setSingleLineTitle(boolean single) {
        this.singleLineTitle = single;
    }

    public boolean isSingleLineTitle() {
        return singleLineTitle;
    }

    public int getOrder() {
        return order;
    }

    public void setOrder(int order) {
        this.order = order;
    }

    public String getDependency() {
        return dependencyKey;
    }

    public void setDependency(String dependencyKey) {
        this.dependencyKey = dependencyKey;
    }

    public void setIcon(Object icon) {
    }

    public void setIcon(int iconResId) {
    }

    public void setLayoutResource(int layoutResId) {
    }

    public void setWidgetLayoutResource(int widgetLayoutResId) {
    }

    public void setFragment(String fragment) {
    }

    public OnPreferenceChangeListener getOnPreferenceChangeListener() {
        return onPreferenceChangeListener;
    }

    public void setOnPreferenceChangeListener(OnPreferenceChangeListener listener) {
        this.onPreferenceChangeListener = listener;
    }

    public OnPreferenceClickListener getOnPreferenceClickListener() {
        return onPreferenceClickListener;
    }

    public void setOnPreferenceClickListener(OnPreferenceClickListener listener) {
        this.onPreferenceClickListener = listener;
    }

    public SummaryProvider<?> getSummaryProvider() {
        return summaryProvider;
    }

    public void setSummaryProvider(SummaryProvider<?> provider) {
        this.summaryProvider = provider;
    }

    public PreferenceManager getPreferenceManager() {
        return preferenceManager;
    }

    void setPreferenceManager(PreferenceManager manager) {
        this.preferenceManager = manager;
    }

    public SharedPreferences getSharedPreferences() {
        return preferenceManager == null ? null : preferenceManager.getSharedPreferences();
    }

    /** As on Android: returns true when the new value may be persisted. */
    public boolean callChangeListener(Object newValue) {
        return onPreferenceChangeListener == null || onPreferenceChangeListener.onPreferenceChange(this, newValue);
    }

    public void notifyChanged() {
    }

    public void notifyDependencyChange(boolean disableDependents) {
    }

    public boolean shouldDisableDependents() {
        return !enabled;
    }

    protected boolean shouldPersist() {
        return preferenceManager != null && persistent && hasKey();
    }

    protected boolean persistString(String value) {
        if (!shouldPersist()) {
            return false;
        }
        getSharedPreferences().edit().putString(key, value).apply();
        return true;
    }

    protected String getPersistedString(String defaultReturnValue) {
        if (!shouldPersist()) {
            return defaultReturnValue;
        }
        return getSharedPreferences().getString(key, defaultReturnValue);
    }

    protected boolean persistBoolean(boolean value) {
        if (!shouldPersist()) {
            return false;
        }
        getSharedPreferences().edit().putBoolean(key, value).apply();
        return true;
    }

    protected boolean getPersistedBoolean(boolean defaultReturnValue) {
        if (!shouldPersist()) {
            return defaultReturnValue;
        }
        return getSharedPreferences().getBoolean(key, defaultReturnValue);
    }

    protected boolean persistStringSet(java.util.Set<String> values) {
        if (!shouldPersist()) {
            return false;
        }
        getSharedPreferences().edit().putStringSet(key, values).apply();
        return true;
    }

    protected java.util.Set<String> getPersistedStringSet(java.util.Set<String> defaultReturnValue) {
        if (!shouldPersist()) {
            return defaultReturnValue;
        }
        return getSharedPreferences().getStringSet(key, defaultReturnValue);
    }

    @Override
    public int compareTo(Preference other) {
        return Integer.compare(order, other.order);
    }

    @Override
    public String toString() {
        return getClass().getSimpleName() + "(key=" + key + ", title=" + title + ")";
    }
}
