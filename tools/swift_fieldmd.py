#!/usr/bin/env python3
# swift_fieldmd.py — 解析 Swift __swift5_fieldmd / __swift5_reflstr 段
# 产出：每个类型的 存储属性名 + 属性类型（mangled），可 demangle 成 Swift 签名
# 用法: python3 swift_fieldmd.py <arm64-slice> <out.json>
import struct, sys, json, subprocess, os

BIN = sys.argv[1] if len(sys.argv) > 1 else '/tmp/frset_sym'
OUT = sys.argv[2] if len(sys.argv) > 2 else '/tmp/frset_fields.json'

data = open(BIN, 'rb').read()
ncmds = struct.unpack('<I', data[16:20])[0]
segs = []  # (segname, vmaddr, vmsize, fileoff, filesize)
sects = {} # name -> (addr, size, foff)
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<II', data[off:off+8])
    if cmd == 0x19:
        segname = data[off+8:off+24].rstrip(b'\0').decode()
        vmaddr, vmsize = struct.unpack('<QQ', data[off+24:off+40])
        fileoff, filesize = struct.unpack('<QQ', data[off+40:off+56])
        segs.append((segname, vmaddr, vmsize, fileoff, filesize))
        nsects = struct.unpack('<I', data[off+64:off+68])[0]
        soff = off + 72
        for _ in range(nsects):
            sname = data[soff:soff+16].rstrip(b'\0').decode()
            addr, size = struct.unpack('<QQ', data[soff+32:soff+48])
            foff = struct.unpack('<I', data[soff+48:soff+52])[0]
            sects[sname] = (addr, size, foff)
            soff += 80
    off += cmdsize

def va2off(va):
    for _, vmaddr, vmsize, fileoff, filesize in segs:
        if vmaddr <= va < vmaddr + vmsize:
            return fileoff + (va - vmaddr)
    return None

def read_cstr(va, limit=200):
    fo = va2off(va)
    if fo is None or fo < 0 or fo >= len(data):
        return None
    end = data.find(b'\0', fo, fo + limit)
    if end < 0: end = fo + limit
    try:
        return data[fo:end].decode('utf-8', errors='replace')
    except Exception:
        return None

fm_addr, fm_size, fm_off = sects['__swift5_fieldmd']
rs_addr, rs_size, rs_off = sects['__swift5_reflstr']
print(f"fieldmd: 0x{fm_addr:x}+0x{fm_size:x}  reflstr: 0x{rs_addr:x}+0x{rs_size:x}")

types = {}
pos = fm_off
end = fm_off + fm_size
count = 0
while pos + 16 <= end:
    desc_va = fm_addr + (pos - fm_off)
    rel_type = struct.unpack('<i', data[pos:pos+4])[0]
    kind_flags = struct.unpack('<H', data[pos+8:pos+10])[0]
    rec_size = struct.unpack('<H', data[pos+10:pos+12])[0]
    num_fields = struct.unpack('<I', data[pos+12:pos+16])[0]
    kind = kind_flags & 0x3
    if kind > 2 or rec_size < 12 or rec_size > 64 or num_fields > 500:
        pos += 4
        continue
    type_va = desc_va + rel_type  # relative to first field (MangledTypeName)
    type_mangled = read_cstr(type_va)
    if not type_mangled or not type_mangled.startswith('$s'):
        pos += 16 + num_fields * rec_size
        continue
    fields = []
    for i in range(num_fields):
        rec_off = pos + 16 + i * rec_size
        rec_va = fm_addr + (rec_off - fm_off)
        t_rel = struct.unpack('<i', data[rec_off+4:rec_off+8])[0]
        n_rel = struct.unpack('<i', data[rec_off+8:rec_off+12])[0]
        f_name = read_cstr(rec_va + 8 + n_rel)
        f_type = read_cstr(rec_va + 4 + t_rel)
        fields.append({"name": f_name, "type": f_type})
    types[type_mangled] = {"kind": ["struct","class","enum"][kind], "fields": fields}
    count += 1
    pos += 16 + num_fields * rec_size

print(f"解析类型: {count}")

# 批量 demangle
mangled_list = list(types.keys())
for t in types.values():
    for f in t["fields"]:
        if f["type"]:
            mangled_list.append(f["type"])
demangled = {}
BATCH = 500
for i in range(0, len(mangled_list), BATCH):
    batch = mangled_list[i:i+BATCH]
    r = subprocess.run(['/Library/Developer/CommandLineTools/usr/bin/swift-demangle'], input='\n'.join(batch), capture_output=True, text=True)
    for src, line in zip(batch, r.stdout.splitlines()):
        line = line.split(' ---> ')[-1].strip()
        demangled[src] = line

out = {}
for m, t in types.items():
    name = demangled.get(m, m)
    # 去掉模块前缀 Frset.
    out[name] = {
        "kind": t["kind"],
        "fields": [{"name": f["name"], "type": demangled.get(f["type"], f["type"])} for f in t["fields"]],
    }

json.dump(out, open(OUT, 'w'), ensure_ascii=False, indent=1)
print(f"输出: {OUT} ({len(out)} 类型)")
