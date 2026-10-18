package androidx.preference;

import android.content.Context;
import android.widget.EditText;

public class EditTextPreference extends DialogPreference {
    public interface OnBindEditTextListener {
        void onBindEditText(EditText editText);
    }

    public static final class SimpleSummaryProvider implements SummaryProvider<EditTextPreference> {
        private static final SimpleSummaryProvider INSTANCE = new SimpleSummaryProvider();

        public static SimpleSummaryProvider getInstance() {
            return INSTANCE;
        }

        @Override
        public CharSequence provideSummary(EditTextPreference preference) {
            String text = preference.getText();
            return text == null || text.isEmpty() ? "Not set" : text;
        }
    }

    private String text;
    private OnBindEditTextListener onBindEditTextListener;

    public EditTextPreference(Context context) {
        super(context);
    }

    public String getText() {
        return text;
    }

    public void setText(String text) {
        this.text = text;
        persistString(text);
    }

    public OnBindEditTextListener getOnBindEditTextListener() {
        return onBindEditTextListener;
    }

    public void setOnBindEditTextListener(OnBindEditTextListener listener) {
        this.onBindEditTextListener = listener;
    }
}
