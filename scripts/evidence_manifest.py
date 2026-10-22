#!/usr/bin/env python3
"""evidence-push upload manifest (spec C3).

hash <dir>             -> JSON list of {path, sha256, md5, crc32c, size}, taken BEFORE upload
upload <dir> <pre.json> <dest> -> SDK fallback using existing application credentials
verify <pre.json> <dest> -> entries (+ object, generation) only for objects whose remote
                           md5 (or crc32c without md5) equals the pre-upload hash; rc 1 unless all.
verify-receipt <receipt> -> re-read all six exact generations and match SHA256 and size.
Without gcloud, verification also fetches the pinned generation and checks SHA256.
DISK_MAGICIAN_STAT_BIN <object> replaces `gcloud storage objects describe` in tests;
pinned receipt checks require DISK_MAGICIAN_TEST_SANDBOX=1 and pass <object>#<generation>.
"""
import base64, hashlib, json, os, shutil, subprocess, sys


def sdk_blob(obj, generation=None):
    from google.cloud import storage
    if not obj.startswith("gs://"):
        raise ValueError("GCS destination required")
    bucket, separator, name = obj[5:].partition("/")
    if not bucket or not separator or not name:
        raise ValueError("GCS object name required")
    return storage.Client().bucket(bucket).blob(name, generation=generation)


def upload(root, manifest, dest):
    """Upload the already-scanned manifest using existing application credentials."""
    if not dest.endswith("/"):
        raise ValueError("destination must end in slash")
    for entry in manifest:
        relative = entry["path"]
        if os.path.isabs(relative) or ".." in relative.split("/"):
            raise ValueError("unsafe manifest path")
        path = os.path.join(root, relative)
        if digests(path) != {key: entry[key] for key in ("sha256", "md5", "crc32c", "size")}:
            raise ValueError("source changed after hashing")
        sdk_blob(dest + relative).upload_from_filename(path, timeout=120)

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


def describe(obj, timeout, generation=None):
    stat = os.environ.get("DISK_MAGICIAN_STAT_BIN")
    # Retirement must read the exact generation, even when gcloud is installed.
    if generation is not None and stat and os.environ.get("DISK_MAGICIAN_TEST_SANDBOX") != "1":
        return {}
    if not stat and (generation is not None or not shutil.which("gcloud")):
        try:
            blob = sdk_blob(obj, generation=int(generation) if generation is not None else None)
            blob.reload(timeout=timeout)
            # Pin the fetched generation; metadata alone does not prove readback.
            sha, size = hashlib.sha256(), 0
            with blob.open("rb", timeout=timeout) as remote:
                while chunk := remote.read(1 << 20):
                    sha.update(chunk)
                    size += len(chunk)
            return dict(generation=str(blob.generation), md5_hash=blob.md5_hash,
                        crc32c_hash=blob.crc32c, sha256=sha.hexdigest(), size=size)
        except Exception:
            return {}
    cmd = [stat, obj + ("#" + str(generation) if generation is not None else "")] if stat else ["gcloud", "storage", "objects", "describe", obj, "--format=json"]
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
    if argv[1] == "verify-receipt":
        try:
            with open(argv[2]) as source:
                objects = json.load(source)["durable_backup"]["objects"]
            if len(objects) != 6:
                return 1
            for entry in objects:
                meta = describe(entry["object"], 30, entry["generation"])
                if (str(meta.get("generation")) != str(entry["generation"])
                        or meta.get("sha256") != entry["sha256"] or meta.get("size") != entry["size"]):
                    print("worktree backup: pinned remote object verification failed", file=sys.stderr)
                    return 1
            return 0
        except Exception as error:
            print("worktree backup: remote verification failed (" + type(error).__name__ + ")", file=sys.stderr)
            return 1
    if argv[1] == "hash":
        root = argv[2]
        json.dump([dict(path=os.path.relpath(p, root), **digests(p)) for d, _, fs in sorted(os.walk(root))
                   for n in sorted(fs) if os.path.isfile(p := os.path.join(d, n))], sys.stdout)
        return 0
    if argv[1] == "upload":
        try:
            with open(argv[3]) as source:
                upload(argv[2], json.load(source), argv[4])
            return 0
        except Exception as error:
            print("evidence-push: SDK upload failed (" + type(error).__name__ + ")", file=sys.stderr)
            return 1
    pre, timeout = json.load(open(argv[2])), float(os.environ.get("DISK_MAGICIAN_STAT_TIMEOUT", 10))
    entries = []
    for e in pre:
        meta = describe(argv[3] + e["path"], timeout)
        md5 = meta.get("md5_hash")
        checksum_ok = md5 == e["md5"] if md5 else meta.get("crc32c_hash") == e["crc32c"]
        if meta.get("generation") and checksum_ok and ("sha256" not in meta or meta["sha256"] == e["sha256"]):
            entries.append(dict(e, object=argv[3] + e["path"], generation=str(meta["generation"])))
    json.dump(entries, sys.stdout)
    return 0 if pre and len(entries) == len(pre) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
