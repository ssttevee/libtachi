package dev.tachi.host;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.lang.ref.Cleaner;
import java.nio.file.Path;
import java.util.Objects;

/** Bounded streaming decoder. No jar extraction, Unsafe, or platform prebuilt code. */
public final class NativeZstdInputStream extends InputStream {
  static {
    String explicit = System.getProperty("tachi.zstd.library");
    // The worker's java.home is <bundle>/runtime/jre, independent of cwd/dataDir.
    Path library = explicit != null ? Path.of(explicit) :
        Path.of(System.getProperty("java.home"), "..", "lib", System.mapLibraryName("pocketmanga-zstd"));
    System.load(library.toAbsolutePath().normalize().toString());
  }
  private static final Cleaner CLEANER = Cleaner.create();
  private static final class State implements Runnable {
    long handle;
    State(long handle) { this.handle = handle; }
    public void run() { if (handle != 0) { destroy(handle); handle = 0; } }
  }
  private final InputStream input;
  private final byte[] compressed = new byte[65536];
  private final int[] progress = new int[3];
  private final State state;
  private final Cleaner.Cleanable cleanable;
  private int position, limit;
  private boolean frameComplete;

  public NativeZstdInputStream(InputStream input) throws IOException {
    this.input = Objects.requireNonNull(input);
    state = new State(create());
    cleanable = CLEANER.register(this, state);
  }
  @Override public synchronized int read(byte[] output, int offset, int count) throws IOException {
    Objects.checkFromIndexSize(offset, count, output.length);
    if (state.handle == 0) throw new IOException("zstd stream closed");
    if (count == 0) return 0;
    for (;;) {
      if (limit == -1) return -1;
      if (frameComplete && position == limit) {
        limit = input.read(compressed);
        position = 0;
        if (limit == -1) return -1;
        if (limit == 0) continue;
      }
      inflate(state.handle, compressed, position, limit - position, output, offset, count, progress);
      position += progress[0];
      frameComplete = progress[2] == 0;
      if (progress[1] != 0) return progress[1];
      if (position != limit && progress[0] == 0) throw new IOException("zstd decoder made no progress");
      if (position == limit) {
        limit = input.read(compressed);
        position = 0;
        if (limit == -1) {
          if (!frameComplete) throw new EOFException("Truncated zstd frame");
          return -1;
        }
      }
    }
  }
  @Override public int read() throws IOException {
    byte[] one = new byte[1];
    return read(one, 0, 1) == -1 ? -1 : one[0] & 255;
  }
  @Override public synchronized void close() throws IOException {
    try { cleanable.clean(); } finally { input.close(); }
  }
  private static native long create() throws IOException;
  private static native void inflate(long handle, byte[] input, int offset, int count,
      byte[] output, int outputOffset, int outputCount, int[] progress) throws IOException;
  private static native void destroy(long handle);
}
