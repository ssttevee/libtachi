package dev.tachi.host;

import java.io.IOException;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import okhttp3.CompressionInterceptor;
import okhttp3.zstd.Zstd;
import okio.Buffer;
import okio.BufferedSource;
import okio.ForwardingSource;
import okio.Okio;
import okio.Source;

/** Standalone test: uses the source-built JNI decoder. */
public final class ZstdCompatibilityTest {
  public static void main(String[] args) throws Exception {
    byte[] encoded;
    try (var resource=ZstdCompatibilityTest.class.getResourceAsStream("/metadata.zst")) { encoded=resource.readAllBytes(); }
    byte[] expected="PocketManga zstd metadata fixture\n".repeat(2048).getBytes(StandardCharsets.UTF_8);
    CompressionInterceptor.DecompressionAlgorithm algorithm=Zstd.INSTANCE;
    if (!algorithm.getEncoding().equals("zstd")) throw new AssertionError("encoding ABI");
    boolean[] closed={false};
    BufferedSource input=Okio.buffer(new ForwardingSource(new Buffer().write(encoded)) {
      @Override public void close() throws IOException { closed[0]=true; super.close(); }
    });
    try (Source decoded=algorithm.decompress(input)) {
      Buffer output=new Buffer();
      while(decoded.read(output, 17)!=-1) {}
      if(!Arrays.equals(expected,output.readByteArray())) throw new AssertionError("decoded bytes");
    }
    if(!closed[0]) throw new AssertionError("underlying source not closed");
    try(Source truncated=algorithm.decompress(new Buffer().write(Arrays.copyOf(encoded,encoded.length-1)))) {
      Buffer output=new Buffer();
      while(truncated.read(output,8192)!=-1) {}
      throw new AssertionError("truncated frame accepted");
    } catch(IOException | IllegalArgumentException expectedFailure) { }
    // Force frame headers, blocks, and checksums across input boundaries.
    try (var tiny = new NativeZstdInputStream(new ByteArrayInputStream(encoded) {
      @Override public synchronized int read(byte[] out, int off, int len) {
        return super.read(out, off, Math.min(1, len));
      }
    })) {
      if (tiny.read(new byte[0]) != 0 || !Arrays.equals(tiny.readAllBytes(), expected))
        throw new AssertionError("single-byte input decoding");
      if (tiny.read() != -1) throw new AssertionError("repeated EOF");
    }
    byte[] concatenated=new byte[encoded.length*2];
    System.arraycopy(encoded,0,concatenated,0,encoded.length);
    System.arraycopy(encoded,0,concatenated,encoded.length,encoded.length);
    try (var frames = new NativeZstdInputStream(new ByteArrayInputStream(concatenated))) {
      byte[] both=frames.readAllBytes();
      if (both.length != expected.length*2 || !Arrays.equals(Arrays.copyOfRange(both,expected.length,both.length),expected))
        throw new AssertionError("concatenated frames");
    }
    byte[] corrupted=encoded.clone();
    corrupted[corrupted.length-1] ^= 1;
    try (var bad = new NativeZstdInputStream(new ByteArrayInputStream(corrupted))) {
      bad.readAllBytes();
      throw new AssertionError("corrupt checksum accepted");
    } catch (IOException expectedFailure) { }
    try (var empty = new NativeZstdInputStream(new ByteArrayInputStream(new byte[0]))) {
      empty.readAllBytes();
      throw new AssertionError("missing frame accepted");
    } catch (IOException expectedFailure) { }
    System.out.println("Native libzstd ABI, streamed/tiny/concatenated decoding, close, checksum and truncated-frame tests passed");
  }
}
