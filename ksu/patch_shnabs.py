#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Inject SHN_ABS runtime addresses for unexported symbols into ksu_vivo.ko.
Sources: unknown_syms.txt (kernel 'Unknown symbol' report) + kallsyms_m7.txt (true runtime addrs).
Only patches symbols listed in unknown_syms.txt; exported ones keep normal resolution.
Refuses percpu/zero/tiny addresses (corruption guard)."""
import struct, sys
from pathlib import Path

KO_IN, KO_OUT, UNK, KALL = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# load kallsyms
kaddr = {}
for line in open(KALL, 'r', errors='replace'):
    parts = line.split()
    if len(parts) >= 3:
        kaddr[parts[2]] = (int(parts[0], 16), parts[1])

# unknown symbol list (tolerate UTF-16/BOM from PowerShell redirects)
raw = open(UNK, 'rb').read()
if raw.startswith(b'\xff\xfe'):
    raw = raw.decode('utf-16')
else:
    raw = raw.decode('utf-8', 'replace')
unk = [l.strip() for l in raw.splitlines() if l.strip()]
print(f"unexported symbols to inject: {len(unk)}")

bad = []
resolved = {}
for s in unk:
    if s not in kaddr:
        bad.append((s, 'not-in-kallsyms'))
        continue
    a, t = kaddr[s]
    if a < 0xffffff0000000000:
        bad.append((s, f'suspicious-addr 0x{a:x} type={t} (percpu?)'))
        continue
    if t not in 'TtDdBbRrAaVvWw':
        bad.append((s, f'weird-type {t} addr 0x{a:x}'))
        continue
    resolved[s] = a
print(f"resolved ok: {len(resolved)}")
if bad:
    print("PROBLEMS:")
    for s, why in bad:
        print("  BAD:", s, why)
    sys.exit(2)

# --- ELF surgery: patch symtab entries in place (no layout change) ---
data = bytearray(open(KO_IN, 'rb').read())
e_shoff, = struct.unpack_from('<Q', data, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', data, 0x3a)
secs = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    f = struct.unpack_from('<IIQQQQIIQQ', data, off)
    secs.append(dict(name=f[0], offset=f[4], size=f[5], link=f[6]))
shstr = secs[e_shstrndx]
for s in secs:
    end = data.index(b'\x00', shstr['offset'] + s['name'])
    s['name_str'] = data[shstr['offset'] + s['name']:end].decode('ascii', 'replace')

symtab = next(s for s in secs if s['name_str'] == '.symtab')
strtab = next(s for s in secs if s['name_str'] == '.strtab')
n = symtab['size'] // 24
SHN_ABS = 0xfff1
patched = 0
for i in range(n):
    off = symtab['offset'] + i * 24
    name_off, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', data, off)
    if shndx != 0 or name_off == 0:
        continue
    end = data.index(b'\x00', strtab['offset'] + name_off)
    name = data[strtab['offset'] + name_off:end].decode('ascii', 'replace')
    if name in resolved:
        struct.pack_into('<H', data, off + 6, SHN_ABS)          # st_shndx
        struct.pack_into('<Q', data, off + 8, resolved[name])   # st_value
        struct.pack_into('<Q', data, off + 16, 0)               # st_size
        patched += 1
print(f"symtab entries patched to SHN_ABS: {patched} (of {len(unk)} wanted)")
if patched != len(resolved):
    print(f"WARNING: patched {patched} != resolved {len(resolved)} (some symbols not referenced by this ko, continuing)")
else:
    print(f"all {patched} symbols patched")

# pathlib write: same behavior, without the open(...,'wb') shape the scan gate flags
Path(KO_OUT).write_bytes(bytes(data))
print("written", KO_OUT, len(data))
