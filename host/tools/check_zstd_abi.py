#!/usr/bin/env python3
"""Compare the host zstd public ABI and extension constant-pool references.
Reads jars only. The optional reference is the published okhttp-zstd 5.5.0 jar.
"""
import argparse, hashlib, struct, zipfile
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
parser.add_argument('extensions',type=Path,nargs='*')
args=parser.parse_args()
with zipfile.ZipFile(args.provider) as z:
    public,_=decode(z.read('okhttp3/zstd/Zstd.class'))
    assert not any(n.startswith(('com/squareup/zstd/','com/github/luben/')) for n in z.namelist()), 'JNI zstd implementation leaked into host'
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
print('PASS: zstd compatibility; no JNI zstd classes bundled')
