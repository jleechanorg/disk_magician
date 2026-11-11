#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARY="${DISK_MAGICIAN_TEST_MEASURE_LIBRARY:-$ROOT/scripts/lib/scratch_budget.sh}"
source "$LIBRARY"
test -n "$TMPDIR" && test -d "$TMPDIR" || exit 2
T="$(mktemp -d "$TMPDIR/dm-leaf-protocol.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
TREE="$T/tree"
mkdir -p "$TREE/a" "$TREE/b" "$TREE/.git/objects"
python3 - "$TREE" <<'PY'
import os,pathlib,sys
root=pathlib.Path(sys.argv[1])
name='large'+chr(9)+'file'+chr(10)+'payload.bin'
large=root/'a'/name
with large.open('wb') as f: f.truncate(100*1024*1024)
os.link(large, root/'b'/'hardlink-alias')
with (root/'.git/objects/large-pack.bin').open('wb') as f: f.truncate(200*1024*1024)
(root/'a'/'small-target').write_bytes(b'link target')
os.symlink(root/'a'/'small-target', root/'a'/'symlink')
PY
MEASURED="$T/measurement.nul"
scratch_budget_measure_files "$TREE" 100 --nul > "$MEASURED"; rc=$?
python3 - "$MEASURED" "$TREE" "$rc" <<'PY'
import pathlib,sys
raw=pathlib.Path(sys.argv[1]).read_bytes(); root=pathlib.Path(sys.argv[2]); rc=int(sys.argv[3])
assert rc==0, (rc, raw[:200])
assert raw.endswith(bytes((0,)))
fields=raw[:-1].split(bytes((0,)))
assert fields[0]==b'diskm-measure-leaves-v1', fields[0]
assert (len(fields)-1)%6==0, len(fields)
rows=[fields[i:i+6] for i in range(1,len(fields),6)]
items={row[4]:row for row in rows}
name='large'+chr(9)+'file'+chr(10)+'payload.bin'
alias=str(root/'b'/'hardlink-alias').encode()
original=str(root/'a'/name).encode()
pack=str(root/'.git/objects/large-pack.bin').encode()
sym=str(root/'a'/'symlink').encode()
for path,size in ((alias,104857600),(original,104857600),(pack,209715200)):
    assert path in items and items[path][3]==b'F' and int(items[path][5])==size,(path,items.get(path))
assert int(items[alias][0])==0 and int(items[original][0])==104857600
assert int(items[alias][2])>0 and int(items[original][2])==int(items[alias][2])
assert sym in items and items[sym][3]==b'L' and int(items[sym][5])<4096
print('NUL protocol: sparse apparent sizes, Git metadata, hardlink age/dedup, tab/newline paths, symlink leaf PASS')
PY
