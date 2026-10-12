#!/usr/bin/env python3
"""Birth audit (spec C7), detection only; a govern tick phase, serialized by govern.lock. Deletes nothing."""
import json, os, sys, time
from pathlib import Path
from disk_budget import state_update
def canon(p): return os.path.join(os.path.realpath(os.path.dirname(p)), os.path.basename(p))
def ls(d, dirs_only=False):  # never follows symlinks
    try: return [e for e in os.scandir(d) if not e.is_symlink() and (e.is_dir() or not dirs_only)] if d else []
    except OSError: return []
def entries(ptmp, tmpdir, codex, wt):  # (path, class, foreign); /private/tmp/<repo>/evidence is a container
    for e in (e for repo in ls(ptmp, True) for e in ls(repo.path)):
        yield from ((c.path, "tmp_containers", False) for c in ls(e.path)) if e.name == "evidence" and e.is_dir() else [(e.path, "tmp_containers", False)]
    for e in ls(tmpdir):  # fixed producer-prefix table: advice-*, tmp* clones with a .git; anything else is foreign
        yield e.path, "tmpdir_scratch", not (e.name.startswith("advice-") or e.name.startswith("tmp") and os.path.lexists(os.path.join(e.path, ".git")))
    for root, cls in ((codex, "codex_documents"), (wt, "worktrees")):
        yield from ((e.path, cls, False) for d in ls(root, True) for e in ls(d.path))
def audit(state, roots, now):  # one birth per sighted generation (canonical path + dev + inode); prints adoptees NUL-separated
    try: reg = json.loads((state / "admission" / "births.json").read_text())
    except (OSError, ValueError): reg = {}
    since, gens, attempts, confirms = reg.get("since", now - 600), reg.get("gens", {}), {}, {}
    try: lines = (state / "admission" / "events.jsonl").read_text().splitlines()
    except OSError: lines = []
    for line in lines:  # attempts are 0/10 admits; a confirm counts only for such an attempt
        try: e = json.loads(line); kind = e["event"]
        except (ValueError, TypeError, KeyError): continue
        if kind == "admit" and e.get("decision") in (0, 10): attempts[e.get("admit_id")] = e
        elif kind == "admit_confirm" and e.get("admit_id") in attempts: confirms[(e.get("dev"), e.get("inode"))] = e
    by_dest = {canon(a["dest"]) for a in attempts.values() if isinstance(a.get("dest"), str)}
    for path, cls, foreign in entries(*roots):
        try: st = os.lstat(path)
        except OSError: continue
        if (key := f"{st.st_dev}:{st.st_ino}") in gens: continue
        c, cp = confirms.get((st.st_dev, st.st_ino)), canon(path)
        status = "preexisting" if getattr(st, "st_birthtime", st.st_ctime) < since else "foreign" if foreign \
            else "admitted" if c and canon(str(c.get("dest"))) == cp else "bypass"
        gens[key] = dict(path=cp, cls=cls, status=status, first_seen=now, producer=attempts[c["admit_id"]].get("producer") if c else None,
                         match="confirmed" if status == "admitted" else "match_unconfirmed" if cp in by_dest else "none")
        if status == "bypass" and cp not in by_dest: sys.stdout.write(path + "\0")
    gens = {k: g for k, g in gens.items() if os.path.lexists(g["path"]) or now - g["first_seen"] < 14 * 86400}
    (tmp := state / "admission" / f".births.{os.getpid()}.tmp").write_text(json.dumps(dict(since=since, gens=gens)))
    os.replace(tmp, state / "admission" / "births.json")
    born, seen = [g for g in gens.values() if g["status"] in ("admitted", "bypass")], {g["path"] for g in gens.values()}
    bypass = {cls: dict(births=sum(g["cls"] == cls and g["status"] == "bypass" for g in born))
              for cls in ("tmp_containers", "tmpdir_scratch", "codex_documents", "worktrees")}
    nb = sum(v["births"] for v in bypass.values())
    state_update(state, dict(births=dict(at=now, coverage="births that persist >= one tick", admitted=len(born) - nb, bypass=bypass,
        foreign=sum(g["status"] == "foreign" for g in gens.values()), ratio=nb / len(born) if born else 0.0, slo_ok=not born or nb / len(born) < 0.10,
        attempt_unconfirmed=sum(not a.get("ci_job") and isinstance(a.get("dest"), str) and canon(a["dest"]) not in seen for a in attempts.values()),
        ci_admission=dict(jobs=len({a["ci_job"] for a in attempts.values() if a.get("ci_job")})))))
def main():
    (state := Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"))).joinpath("admission").mkdir(parents=True, exist_ok=True)
    return audit(state, sys.argv[1:5], time.time()) or 0
if __name__ == "__main__":
    sys.exit(main())
