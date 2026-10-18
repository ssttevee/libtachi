package android.widget;

import android.content.Context;
import android.util.Log;

/** Toasts have no UI here; they are logged instead. */
public class Toast {
    public static final int LENGTH_SHORT = 0;
    public static final int LENGTH_LONG = 1;

    private CharSequence text;

    public Toast(Context context) {
    }

    public static Toast makeText(Context context, CharSequence text, int duration) {
        Toast t = new Toast(context);
        t.text = text;
        return t;
    }

    public static Toast makeText(Context context, int resId, int duration) {
        return makeText(context, "", duration);
    }

    public void setText(CharSequence s) {
        text = s;
    }

    public void setText(int resId) {
    }

    public void setDuration(int duration) {
    }

    public void setGravity(int gravity, int xOffset, int yOffset) {
    }

    public void show() {
        Log.i("Toast", String.valueOf(text));
    }

    public void cancel() {
    }
}
