#!/usr/bin/env python3
"""evidence-push upload manifest (spec C3).

hash <dir>             -> JSON list of {path, sha256, md5, crc32c, size}, taken BEFORE upload
verify <pre.json> <dest> -> entries (+ object, generation) only for objects whose remote
                           md5 (or crc32c without md5) equals the pre-upload hash; rc 1 unless all.
DISK_MAGICIAN_STAT_BIN <object> replaces `gcloud storage objects describe` in tests.
"""
import base64, hashlib, json, os, subprocess, sys

_CRC = []
for i in range(256):
    for _ in range(8):
        i = (i >> 1) ^ 0x82F63B78 if i & 1 else i >> 1
    _CRC.append(i)


def digests(path):
    sha, md5, crc, size = hashlib.sha256(), hashlib.md5(), 0xFFFFFFFF, 0
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            sha.update(chunk), md5.update(chunk)
            size += len(chunk)
            for b in chunk:
                crc = _CRC[(crc ^ b) & 0xFF] ^ (crc >> 8)
    b64 = lambda raw: base64.b64encode(raw).decode()
    return dict(sha256=sha.hexdigest(), md5=b64(md5.digest()), crc32c=b64((crc ^ 0xFFFFFFFF).to_bytes(4, "big")), size=size)


def describe(obj, timeout):
    stat = os.environ.get("DISK_MAGICIAN_STAT_BIN")
    cmd = [stat, obj] if stat else ["gcloud", "storage", "objects", "describe", obj, "--format=json"]
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        try:
            out, _ = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 9)
            p.wait()
            return {}
        return json.loads(out) if p.returncode == 0 else {}
    except (OSError, ValueError):
        return {}


def main(argv):
    if argv[1] == "hash":
        root = argv[2]
        json.dump([dict(path=os.path.relpath(p, root), **digests(p)) for d, _, fs in sorted(os.walk(root))
                   for n in sorted(fs) if os.path.isfile(p := os.path.join(d, n))], sys.stdout)
        return 0
    pre, timeout = json.load(open(argv[2])), float(os.environ.get("DISK_MAGICIAN_STAT_TIMEOUT", 10))
    entries = []
    for e in pre:
        meta = describe(argv[3] + e["path"], timeout)
        md5 = meta.get("md5_hash")
        if meta.get("generation") and (md5 == e["md5"] if md5 else meta.get("crc32c_hash") == e["crc32c"]):
            entries.append(dict(e, object=argv[3] + e["path"], generation=str(meta["generation"])))
    json.dump(entries, sys.stdout)
    return 0 if pre and len(entries) == len(pre) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
