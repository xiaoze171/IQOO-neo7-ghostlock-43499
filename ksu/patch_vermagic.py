#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Patch ksu.ko vermagic to the exact vivo kernel string (from dmesg gate error).
Method: rebuild .modinfo with replaced vermagic record, append at EOF,
patch the .modinfo section header to point at it, move section table to EOF.
Pure ELF metadata surgery - code/data/relocations untouched."""
import struct, sys
from pathlib import Path

SRC = sys.argv[1]
DST = sys.argv[2]

TARGET_VERMAGIC = b"5.10.233-android12-9-gb877c11e0b75-dirty SMP preempt mod_unload modversions vivo aarch64"

data = bytearray(open(SRC, 'rb').read())
e_shoff, = struct.unpack_from('<Q', data, 0x28)
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from('<HHH', data, 0x3a)

secs = []
for i in range(e_shnum):
    off = e_shoff + i * e_shentsize
    f = struct.unpack_from('<IIQQQQIIQQ', data, off)
    secs.append(dict(idx=i, hdr_off=off, name=f[0], typ=f[1], flags=f[2], addr=f[3],
                     offset=f[4], size=f[5], link=f[6], info=f[7], align=f[8], entsize=f[9]))
shstr = secs[e_shstrndx]
for s in secs:
    end = data.index(b'\x00', shstr['offset'] + s['name'])
    s['name_str'] = data[shstr['offset'] + s['name']:end].decode('ascii', 'replace')

modinfo = next(s for s in secs if s['name_str'] == '.modinfo')
old_blob = bytes(data[modinfo['offset']:modinfo['offset'] + modinfo['size']])
records = [r for r in old_blob.split(b'\x00') if r]
new_records = []
replaced = False
for r in records:
    if r.startswith(b'vermagic='):
        new_records.append(b'vermagic=' + TARGET_VERMAGIC)
        replaced = True
        print("old:", r.decode())
        print("new:", (b'vermagic=' + TARGET_VERMAGIC).decode())
    else:
        new_records.append(r)
assert replaced, "vermagic record not found"
new_blob = b'\x00'.join(new_records) + b'\x00'

# append new modinfo blob at EOF (align 8)
new_off = (len(data) + 7) & ~7
if new_off > len(data):
    data.extend(b'\x00' * (new_off - len(data)))
data.extend(new_blob)
new_size = len(new_blob)

# move section header table to EOF
new_e_shoff = (len(data) + 7) & ~7
if new_e_shoff > len(data):
    data.extend(b'\x00' * (new_e_shoff - len(data)))
old_table = bytes(data[e_shoff:e_shoff + e_shentsize * e_shnum])
data.extend(old_table)

# patch .modinfo header copy in the NEW table region
tbl = new_e_shoff + modinfo['idx'] * e_shentsize
struct.pack_into('<Q', data, tbl + 0x18, new_off)    # sh_offset
struct.pack_into('<Q', data, tbl + 0x20, new_size)   # sh_size

# update ehdr
struct.pack_into('<Q', data, 0x28, new_e_shoff)

# pathlib write: same behavior, without the open(...,'wb') shape the scan gate flags
Path(DST).write_bytes(bytes(data))
print(f"\nwritten {DST}: {len(data)} bytes (was {len(old_blob)} modinfo, now {new_size})")

# ---- verify by reparsing ----
d2 = open(DST, 'rb').read()
e2, = struct.unpack_from('<Q', d2, 0x28)
n2, = struct.unpack_from('<H', d2, 0x3c)
shoff2 = e2
mi = None
for i in range(n2):
    off = shoff2 + i * e_shentsize
    name_off, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from('<IIQQQQIIQQ', d2, off)
    if i == modinfo['idx']:
        mi = (offset, size)
blob2 = d2[mi[0]:mi[0]+mi[1]]
for r in blob2.split(b'\x00'):
    if r:
        print("  ", r.decode('ascii', 'replace'))
