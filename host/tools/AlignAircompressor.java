import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import org.objectweb.asm.*;

/** Build-time rewrite, confined to pinned Aircompressor's zstd package.
 * Stack shape is unchanged: Unsafe's receiver becomes the first static argument.
 * No agent, alignment tool, JNI library or source download is needed at runtime.
 */
public final class AlignAircompressor {
    private static final Set<String> WORDS=Set.of("getShort","getInt","getLong","putShort","putInt","putLong");
    public static void main(String[] args) throws Exception {
        Path output=Path.of(args[1]);
        Files.createDirectories(output.getParent());
        int[] replacements={0};
        try(var in=new ZipInputStream(Files.newInputStream(Path.of(args[0])));
            var out=new ZipOutputStream(Files.newOutputStream(output))) {
            ZipEntry entry;
            while((entry=in.getNextEntry())!=null) {
                byte[] bytes=in.readAllBytes();
                if(entry.getName().startsWith("io/airlift/compress/zstd/") && entry.getName().endsWith(".class")) {
                    var writer=new ClassWriter(0);
                    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9,writer) {
                        @Override public MethodVisitor visitMethod(int access,String name,String descriptor,String signature,String[] exceptions) {
                            return new MethodVisitor(Opcodes.ASM9,super.visitMethod(access,name,descriptor,signature,exceptions)) {
                                @Override public void visitMethodInsn(int opcode,String owner,String method,String desc,boolean itf) {
                                    if(owner.equals("sun/misc/Unsafe") && WORDS.contains(method)) {
                                        if(opcode!=Opcodes.INVOKEVIRTUAL || !desc.startsWith("(Ljava/lang/Object;J")) throw new IllegalStateException("Unexpected Unsafe ABI: "+method+desc);
                                        super.visitMethodInsn(Opcodes.INVOKESTATIC,"dev/tachi/host/AlignedUnsafe",method,"(Lsun/misc/Unsafe;"+desc.substring(1),false);
                                        replacements[0]++;
                                    } else super.visitMethodInsn(opcode,owner,method,desc,itf);
                                }
                            };
                        }
                    },0);
                    bytes=writer.toByteArray();
                }
                var target=new ZipEntry(entry.getName()); target.setTime(0);
                out.putNextEntry(target); out.write(bytes); out.closeEntry();
            }
        }
        if(replacements[0]==0) throw new IllegalStateException("No Aircompressor word accesses patched");
        System.out.println("Aircompressor strict-alignment rewrite: "+replacements[0]+" word accesses");
    }
}
