package android.os;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;

/**
 * Stand-in for the Android main looper: a single background thread that
 * executes Handler callbacks in order. Extensions only use it to post work.
 */
public final class Looper {
    private static final Looper MAIN = new Looper("tachi-main");
    private static final ThreadLocal<Looper> CURRENT = new ThreadLocal<>();

    final ScheduledExecutorService executor;
    private volatile Thread thread;

    private Looper(String name) {
        executor = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, name);
            t.setDaemon(true);
            thread = t;
            CURRENT.set(this);
            return t;
        });
    }

    public static Looper getMainLooper() {
        return MAIN;
    }

    public static Looper myLooper() {
        return CURRENT.get();
    }

    public static void prepare() {
    }

    public static void loop() {
    }

    public Thread getThread() {
        return thread;
    }

    public boolean isCurrentThread() {
        return Thread.currentThread() == thread;
    }
}
