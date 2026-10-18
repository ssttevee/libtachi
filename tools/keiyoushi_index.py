#!/usr/bin/env python3
"""List or download extensions from a Keiyoushi-style repo index (index.pb).

The v2 index is a gzip-compressed protobuf. This script decodes it without
a schema (wire-format only), so it has no dependencies.

  tools/keiyoushi_index.py                       # list all
  tools/keiyoushi_index.py --lang en --grep weeb # filter
  tools/keiyoushi_index.py --lang en --grep weeb --download ./exts   # fetch .jar files
  tools/keiyoushi_index.py --apk ...             # fetch .apk instead of .jar

Default index: https://github.com/keiyoushi/extensions/raw/repo/index.pb
"""
import argparse, gzip, io, os, sys, urllib.request

DEFAULT_INDEX = "https://github.com/keiyoushi/extensions/raw/repo/index.pb"

def read_varint(b, i):
    shift = 0; result = 0
    while True:
        c = b[i]; i += 1
        result |= (c & 0x7f) << shift
        if not c & 0x80: return result, i
        shift += 7

def parse(b):
    """Return list of (field_number, wire_type, value)."""
    out = []; i = 0
    while i < len(b):
        key, i = read_varint(b, i)
        f, wt = key >> 3, key & 7
        if wt == 0: v, i = read_varint(b, i)
        elif wt == 1: v, i = b[i:i+8], i + 8
        elif wt == 2:
            n, i = read_varint(b, i); v, i = b[i:i+n], i + n
        elif wt == 5: v, i = b[i:i+4], i + 4
        else: raise ValueError(f"unsupported wire type {wt}")
        out.append((f, wt, v))
    return out

def s(v): return v.decode("utf-8", "replace")

def load_index(url):
    data = urllib.request.urlopen(url).read()
    if data[:2] == b"\x1f\x8b": data = gzip.decompress(data)
    exts = []
    for f, wt, v in parse(data):
        if f != 101: continue
        for ef, ewt, ev in parse(v):
            if ef != 1: continue
            ext = {"sources": []}
            for xf, xwt, xv in parse(ev):
                if xf == 1: ext["name"] = s(xv)
                elif xf == 2: ext["pkg"] = s(xv)
                elif xf == 3:
                    for uf, uwt, uv in parse(xv):
                        if uf == 1: ext["apk"] = s(uv)
                        elif uf == 2: ext["icon"] = s(uv)
                        elif uf == 501: ext["jar"] = s(uv)
                elif xf == 4: ext["lib"] = s(xv)
                elif xf == 5: ext["code"] = xv
                elif xf == 6: ext["version"] = s(xv)
                elif xf == 7: ext["nsfw"] = xv
                elif xf == 8:
                    src = {}
                    for sf, swt, sv in parse(xv):
                        if sf == 1: src["id"] = sv
                        elif sf == 2: src["name"] = s(sv)
                        elif sf == 3: src["lang"] = s(sv)
                        elif sf == 4: src["baseUrl"] = s(sv)
                    ext["sources"].append(src)
            exts.append(ext)
    return exts

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--lang", help="only extensions with a source in this language")
    ap.add_argument("--grep", help="case-insensitive substring of name or package")
    ap.add_argument("--download", metavar="DIR", help="download matching extensions into DIR")
    ap.add_argument("--apk", action="store_true", help="download .apk instead of .jar")
    a = ap.parse_args()
    exts = load_index(a.index)
    if a.lang: exts = [e for e in exts if any(src.get("lang") == a.lang for src in e["sources"])]
    if a.grep:
        g = a.grep.lower(); exts = [e for e in exts if g in e.get("name", "").lower() or g in e.get("pkg", "").lower()]
    for e in exts:
        langs = sorted({src.get("lang", "") for src in e["sources"]})
        print(f"{e.get('pkg')}\t{e.get('version')}\tlib={e.get('lib')}\t{','.join(langs)}\t{e.get('name')}")
    if a.download:
        os.makedirs(a.download, exist_ok=True)
        for e in exts:
            url = e.get("apk") if a.apk else e.get("jar") or e.get("apk")
            if not url: continue
            dest = os.path.join(a.download, url.rsplit("/", 1)[-1])
            if os.path.exists(dest): continue
            print("downloading", url, file=sys.stderr)
            urllib.request.urlretrieve(url, dest)
    print(f"{len(exts)} extension(s)", file=sys.stderr)

if __name__ == "__main__":
    main()
