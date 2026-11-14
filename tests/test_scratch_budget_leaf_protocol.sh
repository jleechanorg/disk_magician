#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARY="${DISK_MAGICIAN_TEST_MEASURE_LIBRARY:-$ROOT/scripts/lib/scratch_budget.sh}"
source "$LIBRARY"
test -n "$TMPDIR" && test -d "$TMPDIR" || exit 2
T="$(mktemp -d "$TMPDIR/dm-leaf-protocol.XXXXXX")" || exit 2
trap 'rm -rf -- "$T"' EXIT
TREE="$T/tree"
mkdir -p "$TREE/a" "$TREE/b" "$TREE/repo/.git/objects"
python3 - "$TREE" <<'PY'
import os,pathlib,sys
root=pathlib.Path(sys.argv[1])
name='large'+chr(9)+'file'+chr(10)+'payload.bin'
large=root/'a'/name
with large.open('wb') as f: f.truncate(100*1024*1024)
os.link(large, root/'b'/'hardlink-alias')
with (root/'repo/.git/objects/large-pack.bin').open('wb') as f: f.truncate(200*1024*1024)
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
repo=str(root/'repo').encode()
pack=str(root/'repo/.git/objects/large-pack.bin').encode()
sym=str(root/'a'/'symlink').encode()
for path,size in ((alias,104857600),(original,104857600)):
    assert path in items and items[path][3]==b'F' and int(items[path][5])==size,(path,items.get(path))
assert int(items[alias][0])==0 and int(items[original][0])==104857600
assert int(items[alias][2])>0 and int(items[original][2])==int(items[alias][2])
assert repo in items and items[repo][3]==b'G' and items[repo][0:3]==[b'0',b'0',b'0'],items.get(repo)
assert not any(path.startswith(repo+b'/') for path in items),items
assert pack not in items
assert sym in items and items[sym][3]==b'L' and int(items[sym][5])<4096
print('NUL protocol: sparse apparent sizes, opaque Git boundary, hardlink age/dedup, tab/newline paths, symlink leaf PASS')
PY
python3 - "$ROOT/scripts/lib/scratch_budget_artifact_children.py" "$T/stream-tree" <<'PY'
import os, pathlib, subprocess, sys
helper, root = sys.argv[1:]
root=pathlib.Path(root); root.mkdir()
for i in range(2000):
    leaf=root/("leaf-%04d" % i); leaf.mkdir(); (leaf/"payload").write_text("x")
proc=subprocess.Popen([sys.executable,helper,"stream-generic-leaves",str(root),""],
                      stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
first=proc.stdout.read(1)
while first and first != b"\0":
    first=proc.stdout.read(1)
assert first == b"\0", first
proc.stdout.close()
rc=proc.wait(timeout=5)
assert rc == 73, rc
print('stream producer: consumer-close returns explicit rc=73 PASS')
PY
