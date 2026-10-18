package androidx.preference;

import android.content.Context;

public abstract class TwoStatePreference extends Preference {
    private boolean checked;
    private CharSequence summaryOn;
    private CharSequence summaryOff;

    public TwoStatePreference(Context context) {
        super(context);
    }

    public boolean isChecked() {
        return checked;
    }

    public void setChecked(boolean checked) {
        this.checked = checked;
        persistBoolean(checked);
    }

    public CharSequence getSummaryOn() {
        return summaryOn;
    }

    public void setSummaryOn(CharSequence summaryOn) {
        this.summaryOn = summaryOn;
    }

    public CharSequence getSummaryOff() {
        return summaryOff;
    }

    public void setSummaryOff(CharSequence summaryOff) {
        this.summaryOff = summaryOff;
    }

    public void setDisableDependentsState(boolean disable) {
    }
}
