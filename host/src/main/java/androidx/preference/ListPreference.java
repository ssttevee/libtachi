package androidx.preference;

import android.content.Context;

public class ListPreference extends DialogPreference {
    public static final class SimpleSummaryProvider implements SummaryProvider<ListPreference> {
        private static final SimpleSummaryProvider INSTANCE = new SimpleSummaryProvider();

        public static SimpleSummaryProvider getInstance() {
            return INSTANCE;
        }

        @Override
        public CharSequence provideSummary(ListPreference preference) {
            CharSequence entry = preference.getEntry();
            return entry == null || entry.length() == 0 ? "Not set" : entry;
        }
    }

    private CharSequence[] entries;
    private CharSequence[] entryValues;
    private String value;

    public ListPreference(Context context) {
        super(context);
    }

    public CharSequence[] getEntries() {
        return entries;
    }

    public void setEntries(CharSequence[] entries) {
        this.entries = entries;
    }

    public void setEntries(int entriesResId) {
    }

    public CharSequence[] getEntryValues() {
        return entryValues;
    }

    public void setEntryValues(CharSequence[] entryValues) {
        this.entryValues = entryValues;
    }

    public void setEntryValues(int entryValuesResId) {
    }

    public String getValue() {
        return value;
    }

    public void setValue(String value) {
        this.value = value;
        persistString(value);
    }

    public void setValueIndex(int index) {
        if (entryValues != null && index >= 0 && index < entryValues.length) {
            setValue(entryValues[index].toString());
        }
    }

    public CharSequence getEntry() {
        int index = getValueIndex();
        return index >= 0 && entries != null && index < entries.length ? entries[index] : null;
    }

    public int findIndexOfValue(String value) {
        if (value != null && entryValues != null) {
            for (int i = entryValues.length - 1; i >= 0; i--) {
                if (entryValues[i].toString().equals(value)) {
                    return i;
                }
            }
        }
        return -1;
    }

    private int getValueIndex() {
        return findIndexOfValue(value);
    }
}
