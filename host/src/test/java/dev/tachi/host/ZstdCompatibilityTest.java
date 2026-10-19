package dev.tachi.host;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import okhttp3.CompressionInterceptor;
import okhttp3.zstd.Zstd;
import okio.Buffer;
import okio.BufferedSource;
import okio.ForwardingSource;
import okio.Okio;
import okio.Source;

/** Standalone test: no test framework or native decoder is needed. */
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
    System.out.println("Pure Java zstd ABI, streamed decoding, close and truncated-frame tests passed");
  }
}
