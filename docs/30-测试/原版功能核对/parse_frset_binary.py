#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Frset 原版二进制全量函数提取器 v2（Mach-O arm64 薄片）
======================================================
输入：/Applications/Frset.app/Contents/MacOS/Frset（universal binary，取 arm64 薄片）
指针编码（本二进制实测）：
  - __DATA/__DATA_CONST 中的 8 字节指针 = (tag << 32) | (vaddr - 0x100000000)
    tag: 0x01 普通指针 / 0x02 列表指针 / 0x04 class_ro / 0x07 名字符串 …
  - method_t（相对方法表）name 字段 → __objc_selrefs 条目 → 再经 tagged 指针 → __objc_methname 字符串
  - Swift 类元数据位于 __data（isa/super/cache/data 同 class_t 布局）
提取：
  A. LC_FUNCTION_STARTS  → 全部函数入口（41,777 个）
  B. ObjC 类（__objc_classlist，536 条）+ 分类 + 协议 + 全部方法（selector + IMP + 类型编码）
  C. Swift 类型描述符（__swift5_types，1462 个）→ demangle
  D. Swift 协议描述符（__swift5_protos，82 个）→ demangle
输出（audit-原版功能核对/）：
  原版-二进制函数清单.csv        全部函数入口（含 ObjC 方法标注）
  原版-ObjC方法明细.csv          类/分类/协议方法级明细
  原版-Swift类型清单.csv         Swift 类型 + 协议
  原版-二进制统计.json
"""
import struct, os, json, subprocess, csv, re

BIN_PATH = "/Applications/Frset.app/Contents/MacOS/Frset"
OUT_DIR = "/Users/sunyiyang/Desktop/Project/frset-rebuild/docs/audit-原版功能核对"
BASE = 0x100000000
ARCH = "arm64"

FAT_MAGIC = 0xcafebabe
MH_MAGIC_64 = 0xfeedfacf
LC_SEGMENT_64 = 0x19
LC_FUNCTION_STARTS = 0x26

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

def find_slice(data, arch):
    magic = u32(data, 0)
    if magic == MH_MAGIC_64:
        return 0, len(data)
    if magic == FAT_MAGIC or magic == 0xbebafeca:
        nfat = struct.unpack_from(">I", data, 4)[0]
        for i in range(nfat):
            off = 8 + i * 20
            cputype = struct.unpack_from(">i", data, off)[0]
            if (arch == "arm64" and cputype == 0x0100000c) or (arch == "x86_64" and cputype == 0x01000007):
                return struct.unpack_from(">I", data, off + 8)[0], struct.unpack_from(">I", data, off + 12)[0]
    raise RuntimeError("slice not found")

def read_uleb128(data, off):
    result = 0; shift = 0
    while True:
        b = data[off]; off += 1
        result |= (b & 0x7f) << shift
        if not (b & 0x80): break
        shift += 7
    return result, off

class MachO:
    def __init__(self, data, base, size):
        self.d = data[base: base + size]
        self.segments = []
        self.sections = {}
        self._parse()

    def _parse(self):
        d = self.d
        self.ncmds = u32(d, 16)
        off = 32
        self.func_starts_meta = None
        for _ in range(self.ncmds):
            cmd = u32(d, off); cmdsize = u32(d, off + 4)
            if cmd == LC_SEGMENT_64:
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, off + 24)
                nsects = u32(d, off + 64)
                self.segments.append(("SEG", vmaddr, vmsize, fileoff, filesize))
                so = off + 72
                for _ in range(nsects):
                    sectname = d[so: so + 16].rstrip(b"\0").decode()
                    addr, size = struct.unpack_from("<QQ", d, so + 32)
                    offset = u32(d, so + 48)
                    self.sections[sectname] = (addr, size, offset)
                    so += 80
            elif cmd == LC_FUNCTION_STARTS:
                loff, lsize = struct.unpack_from("<II", d, off + 8)
                self.func_starts_meta = (loff, lsize)
            off += cmdsize

    def vaddr_to_off(self, vaddr):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if vmaddr <= vaddr < vmaddr + vmsize:
                if vaddr < vmaddr + filesize:
                    return fileoff + (vaddr - vmaddr)
        return None

    def off_to_vaddr(self, off):
        for _, vmaddr, vmsize, fileoff, filesize in self.segments:
            if fileoff <= off < fileoff + filesize:
                return vmaddr + (off - fileoff)
        return None

    def sect_range(self, name):
        if name in self.sections:
            a, s, _ = self.sections[name]
            return (a, a + s)
        return None

    def cstr(self, vaddr):
        o = self.vaddr_to_off(vaddr)
        if o is None: return None
        e = self.d.index(b"\0", o)
        try:
            return self.d[o:e].decode("utf-8")
        except UnicodeDecodeError:
            return None

    def func_starts(self):
        loff, lsize = self.func_starts_meta
        data = self.d[loff: loff + lsize]
        text = next(s for s in self.segments if s[1] == 0x100000000)
        addr = text[1]; out = []; off = 0
        while off < len(data):
            delta, off = read_uleb128(data, off)
            addr += delta
            out.append(addr)
        return out

class Extractor:
    def __init__(self, m: MachO):
        self.m = m
        self.methods = []
        self.classes = []
        self.categories = []
        self.protocols = []
        self.selref_range = m.sect_range("__objc_selrefs")
        self.classname_range = m.sect_range("__objc_classname")
        self.methlist_range = m.sect_range("__objc_methlist")

    def _in(self, va, rng):
        return rng is not None and rng[0] <= va < rng[1]

    def resolve(self, v, validator=None):
        low = v & 0xFFFFFFFF
        cands = [BASE + low]
        if low & 3:
            cands.append(BASE + (low & ~3))
        for c in cands:
            if self.m.vaddr_to_off(c) is None:
                continue
            if validator is None or validator(c):
                return c
        return cands[0] if self.m.vaddr_to_off(cands[0]) is not None else None

    def _sel_from_va(self, va):
        if self._in(va, self.selref_range):
            o = self.m.vaddr_to_off(va)
            if o is not None:
                v2 = u64(self.m.d, o)
                s = self.m.cstr(BASE + (v2 & 0xFFFFFFFF))
                if s: return s
        s = self.m.cstr(va)
        if s: return s
        if va & 3:
            return self.m.cstr(va & ~3)
        return None

    def parse_method_list(self, list_va, owner, owner_kind, mkind):
        o = self.m.vaddr_to_off(list_va)
        if o is None: return 0
        eaf = u32(self.m.d, o); cnt = u32(self.m.d, o + 4)
        if cnt > 2000: return 0
        entsize = eaf & 0xFFFF; flags = eaf & 0xFFFF0000
        relative = bool(flags & 0x80000000)
        n = 0
        for i in range(cnt):
            if relative and entsize == 12:
                eo = o + 8 + i * 12
                fva = self.m.off_to_vaddr(eo)
                nrel = struct.unpack_from("<i", self.m.d, eo)[0]
                trel = struct.unpack_from("<i", self.m.d, eo + 4)[0]
                irel = struct.unpack_from("<i", self.m.d, eo + 8)[0]
                sel = self._sel_from_va(fva + nrel)
                types = self.m.cstr(fva + 4 + trel)
                imp = fva + 8 + irel
                imp_zero = (irel == 0)
            else:
                eo = o + 8 + i * entsize
                name_ptr = u64(self.m.d, eo)
                types_ptr = u64(self.m.d, eo + 8)
                imp = u64(self.m.d, eo + 16)
                sel = self._sel_from_va(BASE + (name_ptr & 0xFFFFFFFF))
                types = self.m.cstr(BASE + (types_ptr & 0xFFFFFFFF))
                imp = BASE + (imp & 0xFFFFFFFF) if imp < BASE else imp
                imp_zero = (imp == 0)
            if sel:
                self.methods.append({"owner": owner, "owner_kind": owner_kind, "mkind": mkind,
                                     "selector": sel, "types": types or "", "imp": imp,
                                     "imp_zero": imp_zero})
                n += 1
        return n

    def parse_class(self, cls_va):
        o = self.m.vaddr_to_off(cls_va)
        if o is None: return
        isa_v = u64(self.m.d, o)
        data_v = u64(self.m.d, o + 32)
        ro_va = self.resolve(data_v, lambda c: self._in(c, self.m.sect_range("__objc_const")))
        if ro_va is None: return
        ro = self.m.vaddr_to_off(ro_va)
        if ro is None: return
        name_v = u64(self.m.d, ro + 24)
        name_va = self.resolve(name_v, lambda c: self._in(c, self.classname_range))
        name = self.m.cstr(name_va) if name_va else None
        if not name or len(name) > 300 or not all(32 <= ord(c) < 127 for c in name):
            return
        ml_v = u64(self.m.d, ro + 32)
        n_inst = 0
        ml_va = self.resolve(ml_v, lambda c: self._in(c, self.methlist_range))
        if ml_va:
            n_inst = self.parse_method_list(ml_va, name, "class", "instance")
        n_cls = 0
        isa_va = self.resolve(isa_v, lambda c: self._in(c, self.m.sect_range("__objc_data")) or self._in(c, self.m.sect_range("__data")))
        if isa_va:
            mo = self.m.vaddr_to_off(isa_va)
            if mo is not None:
                mdata_v = u64(self.m.d, mo + 32)
                mro_va = self.resolve(mdata_v, lambda c: self._in(c, self.m.sect_range("__objc_const")))
                if mro_va:
                    mro = self.m.vaddr_to_off(mro_va)
                    if mro is not None:
                        mml_v = u64(self.m.d, mro + 32)
                        mml_va = self.resolve(mml_v, lambda c: self._in(c, self.methlist_range))
                        if mml_va:
                            n_cls = self.parse_method_list(mml_va, name, "class", "class")
        self.classes.append((name, cls_va, n_inst, n_cls))

    def parse_categories(self):
        rng = self.m.sect_range("__objc_catlist")
        if not rng: return
        addr, end = rng
        for i in range((end - addr) // 8):
            o = self.m.vaddr_to_off(addr + i * 8)
            cat_va = BASE + (u64(self.m.d, o) & 0xFFFFFFFF)
            co = self.m.vaddr_to_off(cat_va)
            if co is None: continue
            name_va = self.resolve(u64(self.m.d, co), lambda c: self._in(c, self.classname_range))
            name = self.m.cstr(name_va) if name_va else None
            if not name: continue
            for off, mk in ((16, "instance"), (24, "class")):
                v = u64(self.m.d, co + off)
                lv = self.resolve(v, lambda c: self._in(c, self.methlist_range))
                if lv: self.parse_method_list(lv, name, "category", mk)
            self.categories.append(name)

    def parse_objc_protocols(self):
        rng = self.m.sect_range("__objc_protolist")
        if not rng: return
        addr, end = rng
        for i in range((end - addr) // 8):
            o = self.m.vaddr_to_off(addr + i * 8)
            p_va = BASE + (u64(self.m.d, o) & 0xFFFFFFFF)
            po = self.m.vaddr_to_off(p_va)
            if po is None: continue
            name_va = self.resolve(u64(self.m.d, po + 8), lambda c: self._in(c, self.classname_range))
            name = self.m.cstr(name_va) if name_va else None
            if not name or not all(32 <= ord(c) < 127 for c in name): continue
            for off, mk in ((24, "instance"), (32, "class"), (40, "instance@optional"), (48, "class@optional")):
                v = u64(self.m.d, po + off)
                lv = self.resolve(v, lambda c: self._in(c, self.methlist_range))
                if lv: self.parse_method_list(lv, name, "protocol", mk)
            self.protocols.append(name)

    def run(self):
        rng = self.m.sect_range("__objc_classlist")
        if rng:
            addr, end = rng
            for i in range((end - addr) // 8):
                o = self.m.vaddr_to_off(addr + i * 8)
                cls_va = BASE + (u64(self.m.d, o) & 0xFFFFFFFF)
                self.parse_class(cls_va)
        found = {c[1] for c in self.classes}
        for sect in ("__objc_data", "__data"):
            rng = self.m.sect_range(sect)
            if not rng: continue
            addr, end = rng
            o0 = self.m.vaddr_to_off(addr)
            for off in range(0, end - addr - 40, 8):
                va = addr + off
                if va in found: continue
                o = o0 + off
                data_v = u64(self.m.d, o + 32)
                ro_va = BASE + (data_v & 0xFFFFFFFF)
                if not self._in(ro_va, self.m.sect_range("__objc_const")): continue
                ro = self.m.vaddr_to_off(ro_va)
                if ro is None: continue
                name_va = BASE + (u64(self.m.d, ro + 24) & 0xFFFFFFFF)
                if not self._in(name_va, self.classname_range): continue
                nm = self.m.cstr(name_va)
                if nm and len(nm) < 300 and all(32 <= ord(c) < 127 for c in nm):
                    self.parse_class(va)
        self.parse_categories()
        self.parse_objc_protocols()

def parse_swift(m: MachO):
    types, protos = [], []

    def desc_name(desc_addr):
        o = m.vaddr_to_off(desc_addr)
        if o is None: return None, None
        nrel = struct.unpack_from("<i", m.d, o + 8)[0]
        flags = u32(m.d, o)
        kind = flags & 0x1F
        return m.cstr(desc_addr + 8 + nrel), kind

    for sect, out in (("__swift5_types", types), ("__swift5_protos", protos)):
        rng = m.sect_range(sect)
        if not rng: continue
        addr, end = rng
        for i in range((end - addr) // 4):
            ea = addr + i * 4
            o = m.vaddr_to_off(ea)
            rel = struct.unpack_from("<i", m.d, o)[0]
            name, kind = desc_name(ea + rel)
            if name:
                out.append((name, kind))
    return types, protos

KIND_MAP = {16: "class", 17: "struct", 18: "enum"}

def demangle(names):
    if not names: return {}
    uniq = sorted(set(names)); out = {}
    for i in range(0, len(uniq), 2000):
        chunk = uniq[i:i + 2000]
        p = subprocess.run(["xcrun", "swift-demangle"], input="\n".join(chunk),
                           capture_output=True, text=True)
        for src, dst in zip(chunk, p.stdout.splitlines()):
            out[src] = dst if not dst.startswith(("$s", "_$s")) else src
    return out

def main():
    with open(BIN_PATH, "rb") as f:
        data = f.read()
    foff, fsize = find_slice(data, ARCH)
    print(f"arm64 slice: off={foff} size={fsize}")
    m = MachO(data, foff, fsize)

    starts = m.func_starts()
    print(f"LC_FUNCTION_STARTS: {len(starts)} functions")

    ex = Extractor(m)
    ex.run()
    print(f"ObjC: {len(ex.classes)} classes, {len(ex.categories)} categories, "
          f"{len(ex.protocols)} protocols, {len(ex.methods)} methods")

    stypes, sprotos = parse_swift(m)
    print(f"Swift: {len(stypes)} type descriptors, {len(sprotos)} protocols")
    func_set = set(starts)
    dem = demangle([t for t, _ in stypes] + [p for p, _ in sprotos])
    stats = {
        "binary": BIN_PATH, "arch": ARCH,
        "functions_total": len(starts),
        "objc_classes": len(ex.classes),
        "objc_categories": len(ex.categories),
        "objc_protocols": len(ex.protocols),
        "objc_methods": len(ex.methods),
        "objc_methods_imp_in_funcstarts": sum(1 for x in ex.methods if x["imp"] in func_set),
        "swift_type_descriptors": len(stypes),
        "swift_protocols": len(sprotos),
    }
    # ObjC 类名 demangle（_TtC5Frset8XxxC → Frset.Xxx）
    raw_names = [c[0] for c in ex.classes]
    cdem = demangle(raw_names)
    THIRD_PARTY = ("Sentry", "PostHog", "PLCrash", "PHURLSessionTaskSafeAccess")
    def module_of(name):
        d = cdem.get(name, name)
        if d.startswith(("Sentry", "PrivateSentry", "_Sentry")):
            return "Sentry(第三方)"
        if d.startswith(("PostHog", "PH")):
            return "PostHog(第三方)"
        if d.startswith("PLCrash"):
            return "PLCrashReporter(第三方)"
        if "." in d and not d.startswith(("NS", "CF", "CG", "EK", "__")):
            return d.split(".")[0]
        return "ObjC/其他"
    class_rows = []
    for name, va, ni, nc in ex.classes:
        d = cdem.get(name, name)
        # 私有类型：Frset.(Xxx in _HASH) → Xxx
        m2 = re.match(r"^(.*?)\.\((.*?) in _[0-9A-F]+\)$", d)
        if m2:
            d = m2.group(1) + "." + m2.group(2)
        short = d.split(".")[-1] if "." in d else d
        class_rows.append((name, d, short, module_of(name), ni, nc))
    with open(os.path.join(OUT_DIR, "原版-类清单.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["二进制类名", "demangled名", "短名", "模块", "实例方法数", "类方法数"])
        for r in sorted(class_rows, key=lambda x: (x[3], x[2])):
            w.writerow(r)

    stats["frset_module_classes"] = sum(1 for r in class_rows if r[3] == "Frset")
    stats["third_party_classes"] = sum(1 for r in class_rows if "第三方" in r[3])
    with open(os.path.join(OUT_DIR, "原版-二进制统计.json"), "w") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)

    with open(os.path.join(OUT_DIR, "原版-ObjC方法明细.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["归属", "demangled归属", "模块", "归属种类", "方法类型", "选择器", "类型编码", "IMP地址", "IMP是函数入口"])
        meth_rows = []
        for meth in ex.methods:
            d = cdem.get(meth["owner"], meth["owner"])
            meth_rows.append((meth, d, module_of(meth["owner"])))
        for meth, d, mod in sorted(meth_rows, key=lambda x: (x[2], x[1], x[0]["mkind"], x[0]["selector"])):
            if meth.get("imp_zero"):
                imp_ok = "协议要求(IMP=0)"
            elif meth["imp"] in func_set:
                imp_ok = "是"
            else:
                imp_ok = "否"
            w.writerow([meth["owner"], d, mod, meth["owner_kind"], meth["mkind"], meth["selector"],
                        meth["types"], hex(meth["imp"]), imp_ok])

    imp_owner = {}
    for meth in ex.methods:
        imp_owner.setdefault(meth["imp"], f'{meth["owner"]} {meth["mkind"]}:{meth["selector"]}')
    with open(os.path.join(OUT_DIR, "原版-二进制函数清单.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["序号", "函数入口地址", "ObjC标注", "是否ObjC方法"])
        for i, a in enumerate(sorted(starts), 1):
            owner = imp_owner.get(a, "")
            w.writerow([i, hex(a), owner, "是" if owner else "否"])

    with open(os.path.join(OUT_DIR, "原版-Swift类型清单.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["类型名", "种类", "来源"])
        seen = set()
        for t, kind in sorted(stypes):
            k = KIND_MAP.get(kind, f"kind{kind}")
            if t not in seen:
                seen.add(t)
                w.writerow([t, k, "__swift5_types"])
        for p, kind in sorted(sprotos):
            if p not in seen:
                seen.add(p)
                w.writerow([p, "protocol", "__swift5_protos"])

    print(json.dumps(stats, indent=2))
    print("done.")

if __name__ == "__main__":
    main()
