#!/usr/bin/env python3
"""Compare the host zstd public ABI and extension constant-pool references.
Reads jars only. The optional reference is the published okhttp-zstd 5.5.0 jar.
"""
import argparse, hashlib, struct, zipfile, re, shutil, subprocess
from pathlib import Path

def decode(data):
    at=8
    def u1():
        nonlocal at
        n=data[at]; at+=1; return n
    def u2():
        nonlocal at
        n=struct.unpack_from('>H',data,at)[0]; at+=2; return n
    def u4():
        nonlocal at
        n=struct.unpack_from('>I',data,at)[0]; at+=4; return n
    pool=[None]*u2()
    i=1
    while i<len(pool):
        tag=u1()
        if tag==1:
            n=u2(); pool[i]=(tag,data[at:at+n].decode('utf-8',errors='replace')); at+=n
        elif tag in (3,4): at+=4
        elif tag in (5,6): at+=8; i+=1
        elif tag in (7,8,16,19,20): pool[i]=(tag,u2())
        elif tag in (9,10,11,12,17,18): pool[i]=(tag,u2(),u2())
        elif tag==15: at+=3
        else: raise ValueError(f'Unknown constant tag {tag}')
        i+=1
    text=lambda index: pool[index][1]
    name=lambda index: text(pool[index][1])
    refs=set()
    for item in pool[1:]:
        if item and item[0] in (9,10,11) and name(item[1]).startswith('okhttp3/zstd/'):
            member=pool[item[2]]
            refs.add((name(item[1]),text(member[1]),text(member[2])))
    flags=u2(); owner=name(u2()); u2()
    for _ in range(u2()): u2()
    def attributes():
        nonlocal at
        for _ in range(u2()):
            u2(); length=u4(); at+=length
    public=set()
    for section in range(2):
        for _ in range(u2()):
            access=u2(); member=text(u2()); descriptor=text(u2())
            if access & 1: public.add((owner,member,descriptor,access))
            attributes()
    return public,refs

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--provider',type=Path,default=Path(__file__).resolve().parents[1]/'build/libs/tachi-host.jar')
parser.add_argument('--reference',type=Path)
parser.add_argument('--native', type=Path, help='Audit the source-built ARM JNI shared library')
parser.add_argument('extensions',type=Path,nargs='*')
args=parser.parse_args()
with zipfile.ZipFile(args.provider) as z:
    public,_=decode(z.read('okhttp3/zstd/Zstd.class'))
    assert 'dev/tachi/host/NativeZstdInputStream.class' in z.namelist()
    assert not any(n.startswith(('io/airlift/compress/', 'dev/tachi/host/AlignedUnsafe', 'com/squareup/zstd/', 'com/github/luben/')) for n in z.namelist()), 'Obsolete or extracting decoder bundled'
if args.reference:
    with zipfile.ZipFile(args.reference) as z: reference,_=decode(z.read('okhttp3/zstd/Zstd.class'))
    assert public==reference, (public,reference)
    print('Published okhttp-zstd public fields/methods/descriptors/access flags match exactly')
provided={item[:3] for item in public}
for extension in args.extensions:
    refs=set()
    with zipfile.ZipFile(extension) as z:
        for name in z.namelist():
            if name.endswith('.class'):
                data=z.read(name)
                if b'okhttp3/zstd/' in data: refs.update(decode(data)[1])
    assert refs, 'No zstd references found: '+str(extension)
    assert refs<=provided, refs-provided
    print(extension.name, 'sha256='+hashlib.sha256(extension.read_bytes()).hexdigest())
    for ref in sorted(refs): print('  '+'.'.join(ref[:2])+' '+ref[2])
if args.native:
    readelf=shutil.which('llvm-readelf') or '/opt/homebrew/opt/llvm/bin/llvm-readelf'
    header=subprocess.check_output([readelf,'-h','-A',str(args.native)],text=True)
    flags=int(re.search(r'Flags:\s+(0x[0-9a-fA-F]+)',header).group(1),16)
    assert 'ARM' in header and flags & 0x200 and not flags & 0x400, header
    dynamic=subprocess.check_output([readelf,'-d',str(args.native)],text=True)
    needed=re.findall(r'\(NEEDED\).*\[([^]]+)\]',dynamic)
    assert needed == ['libc.so.6'], needed
    symbols=subprocess.check_output([readelf,'--dyn-syms','--wide',str(args.native)],text=True)
    versions=re.findall(r'@GLIBC_([0-9.]+)',symbols)
    maximum=max(versions,key=lambda v:tuple(map(int,v.split('.'))))
    assert tuple(map(int,maximum.split('.'))) <= (2,17), maximum
    for method in ('create','inflate','destroy'):
        assert 'Java_dev_tachi_host_NativeZstdInputStream_'+method in symbols
    print('ARM soft-float JNI: NEEDED='+','.join(needed)+' max GLIBC='+maximum)
print('PASS: zstd ABI and bundled JNI provider')
