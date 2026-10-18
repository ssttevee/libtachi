package androidx.preference;

import android.content.Context;

public abstract class DialogPreference extends Preference {
    private CharSequence dialogTitle;
    private CharSequence dialogMessage;
    private CharSequence positiveButtonText;
    private CharSequence negativeButtonText;

    public DialogPreference(Context context) {
        super(context);
    }

    public CharSequence getDialogTitle() {
        return dialogTitle;
    }

    public void setDialogTitle(CharSequence dialogTitle) {
        this.dialogTitle = dialogTitle;
    }

    public void setDialogTitle(int dialogTitleResId) {
    }

    public CharSequence getDialogMessage() {
        return dialogMessage;
    }

    public void setDialogMessage(CharSequence dialogMessage) {
        this.dialogMessage = dialogMessage;
    }

    public void setDialogMessage(int dialogMessageResId) {
    }

    public CharSequence getPositiveButtonText() {
        return positiveButtonText;
    }

    public void setPositiveButtonText(CharSequence text) {
        this.positiveButtonText = text;
    }

    public CharSequence getNegativeButtonText() {
        return negativeButtonText;
    }

    public void setNegativeButtonText(CharSequence text) {
        this.negativeButtonText = text;
    }

    public void setDialogIcon(Object icon) {
    }

    public void setDialogLayoutResource(int dialogLayoutResId) {
    }
}
