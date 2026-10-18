package android.os;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/** Executes Runnables on a Looper's thread. Only the posting subset of the API is provided. */
public class Handler {
    public interface Callback {
        boolean handleMessage(Message msg);
    }

    private final Looper looper;
    private final Map<Runnable, ScheduledFuture<?>> pending = new ConcurrentHashMap<>();

    public Handler() {
        this(Looper.getMainLooper());
    }

    public Handler(Callback callback) {
        this(Looper.getMainLooper());
    }

    public Handler(Looper looper) {
        this.looper = looper == null ? Looper.getMainLooper() : looper;
    }

    public Handler(Looper looper, Callback callback) {
        this(looper);
    }

    public Looper getLooper() {
        return looper;
    }

    public boolean post(Runnable r) {
        return postDelayed(r, 0);
    }

    public boolean postDelayed(Runnable r, long delayMillis) {
        ScheduledFuture<?> f = looper.executor.schedule(() -> {
            pending.remove(r);
            r.run();
        }, Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
        pending.put(r, f);
        return true;
    }

    public boolean postAtFrontOfQueue(Runnable r) {
        return post(r);
    }

    public void removeCallbacks(Runnable r) {
        ScheduledFuture<?> f = pending.remove(r);
        if (f != null) {
            f.cancel(false);
        }
    }

    public void removeCallbacksAndMessages(Object token) {
        for (ScheduledFuture<?> f : pending.values()) {
            f.cancel(false);
        }
        pending.clear();
    }
}
