import json
from pathlib import Path
import pytest
from scripts.directory_inventory import publish_inventory, read_current


def row(path='/a', amount=0):
    return {'filesystem_id':'fs-a','mountpoint':'/','canonical_path':path,
            'path_generation':{'id':'g1','status':'known'},
            'observation':{'scan_id':'s1','started_at':'2026-10-24T00:00:00Z','ended_at':'2026-10-24T00:01:00Z','allocated_bytes':amount,'apparent_bytes':amount,'size_semantics':'inclusive','source':'frontier','measurement_status':'measured','subtree_coverage_status':'complete','comparable':True},
            'attribution':{'basis':'filesystem','capability':'logical','comparability':'same-fs','reason':None}}


def test_publishes_sorted_partial_unknown_and_zero(tmp_path):
    result=publish_inventory([row('/z',0),row('/a',7)],state_dir=tmp_path,now='2026-10-24T00:00:00Z')
    assert result['pointer']['complete'] is False
    read=read_current(tmp_path)
    assert [r['canonical_path'] for r in read['records']]==['/a','/z']
    assert read['records'][1]['observation']['allocated_bytes']==0
    assert read['manifest']['unresolved_frontier']==['/']


def test_failed_pointer_publish_preserves_previous(tmp_path):
    first=publish_inventory([row('/first',1)],state_dir=tmp_path,now='t1')
    def fail(stage):
        if stage=='pointer.staged': raise OSError('injected')
    with pytest.raises(OSError): publish_inventory([row('/second',2)],state_dir=tmp_path,now='t2',failure_hook=fail)
    assert read_current(tmp_path)['pointer']['manifest_sha256']==first['pointer']['manifest_sha256']


def test_detects_corrupt_manifest(tmp_path):
    result=publish_inventory([row()],state_dir=tmp_path,now='t')
    path=tmp_path/'inventory'/'manifests'/(result['pointer']['manifest_sha256']+'.json')
    path.write_text('{}')
    with pytest.raises(ValueError,match='manifest hash'):
        read_current(tmp_path)


def test_rejects_overlap_with_git_state(tmp_path):
    with pytest.raises(ValueError,match='separate'):
        publish_inventory([],state_dir=tmp_path/'state',git_state_repo=tmp_path)

def test_read_publication_uses_exact_manifest_and_checks_identity_graph(tmp_path):
    from scripts.directory_inventory import read_publication
    first=publish_inventory([row('/first',1)],state_dir=tmp_path,now='t1')
    second=publish_inventory([row('/second',2)],state_dir=tmp_path,now='t2')
    old=read_publication(tmp_path,first['pointer']['manifest_sha256'])
    assert old['records'][0]['canonical_path']=='/first'
    event_hash=old['manifest']['identity_event_manifest_sha256']
    identity=tmp_path/'inventory'/'objects'/(event_hash+'.identity.json')
    identity.write_bytes(b'{}')
    with pytest.raises(ValueError,match='identity_event_manifest_sha256 hash'):
        read_publication(tmp_path,first['pointer']['manifest_sha256'])


def test_complete_rejects_unresolved_frontier(tmp_path):
    with pytest.raises(ValueError,match='unresolved frontier'):
        publish_inventory([row()],state_dir=tmp_path,complete=True,unresolved_frontier=['/blocked'])

def test_read_publication_keeps_historical_generation_exact(tmp_path):
    from scripts.directory_inventory import read_publication
    old=publish_inventory([row('/old',1)],state_dir=tmp_path,now='t1')
    publish_inventory([row('/new',2)],state_dir=tmp_path,now='t2')
    assert read_publication(tmp_path,old['pointer']['manifest_sha256'])['records'][0]['canonical_path']=='/old'


def test_root_import_validates_source_and_preserves_exact_provenance(tmp_path):
    import os
    from scripts.directory_inventory import import_root_publication
    root=tmp_path/'root'; user=tmp_path/'user'
    original=publish_inventory([row('/source',3)],state_dir=root,complete=True,now='2026-10-24T00:00:00+00:00')
    import stat
    for directory in (root/'inventory', root/'inventory'/'manifests', root/'inventory'/'objects', root/'inventory'/'indexes'):
        directory.chmod(0o755)
    for path in (root/'inventory').rglob('*'):
        if path.is_file(): path.chmod(0o644)
    imported=import_root_publication(root,state_dir=user,now='2026-10-24T00:01:00+00:00',trusted_uid=os.getuid())
    current=read_current(user)
    assert current['records'][0]['canonical_path']=='/source'
    assert current['manifest']['provenance']['source_manifest_sha256']==original['pointer']['manifest_sha256']
    assert current['manifest']['complete'] is True


def test_retention_separates_measurement_and_identity_expiry(tmp_path):
    from datetime import datetime, timedelta, timezone
    from scripts.directory_inventory import prune_retained, retention_status
    start=datetime(2026,1,1,tzinfo=timezone.utc)
    old=publish_inventory([row('/old',1)],state_dir=tmp_path,now=start.isoformat())
    day36=publish_inventory([row('/day36',2)],state_dir=tmp_path,now=(start+timedelta(days=36)).isoformat())
    day90=publish_inventory([row('/day90',3)],state_dir=tmp_path,now=(start+timedelta(days=90)).isoformat())
    current=publish_inventory([row('/current',4)],state_dir=tmp_path,now=(start+timedelta(days=91)).isoformat())
    status=retention_status(tmp_path,now=start+timedelta(days=91))['manifests']
    indexed={x['sha256']:x for x in status}
    assert indexed[old['pointer']['manifest_sha256']]['measurement_retained'] is False
    assert indexed[old['pointer']['manifest_sha256']]['identity_retained'] is False
    assert indexed[day36['pointer']['manifest_sha256']]['measurement_retained'] is False
    assert indexed[day36['pointer']['manifest_sha256']]['identity_retained'] is True
    assert indexed[day90['pointer']['manifest_sha256']]['identity_retained'] is True
    removed=prune_retained(tmp_path,now=start+timedelta(days=91))
    old_manifest=tmp_path/'inventory'/'manifests'/(old['pointer']['manifest_sha256']+'.json')
    assert not old_manifest.exists()
    assert (tmp_path/'inventory'/'manifests'/(day36['pointer']['manifest_sha256']+'.json')).exists()
    assert current['pointer']['manifest_sha256'] not in [x for x in removed]


def test_active_pin_blocks_pruning_then_unpin_releases(tmp_path):
    from datetime import datetime, timedelta, timezone
    from scripts.directory_inventory import pin_publication, prune_retained, unpin_publication
    start=datetime(2026,1,1,tzinfo=timezone.utc)
    old=publish_inventory([row('/old',1)],state_dir=tmp_path,now=start.isoformat())
    pin_publication(tmp_path,old['pointer']['manifest_sha256'],'snapshot-writer',
                    expires_at=(datetime.now(timezone.utc)+timedelta(minutes=30)).isoformat())
    publish_inventory([row('/new',2)],state_dir=tmp_path,now=(start+timedelta(days=91)).isoformat())
    prune_retained(tmp_path,now=datetime.now(timezone.utc))
    assert (tmp_path/'inventory'/'manifests'/(old['pointer']['manifest_sha256']+'.json')).exists()
    assert unpin_publication(tmp_path,old['pointer']['manifest_sha256'],'snapshot-writer') is True


def test_historical_event_provenance_merges_idempotently_without_replacing_scan_metadata(tmp_path):
    first = publish_inventory([row('/live', 4)], state_dir=tmp_path, now='t1',
        scan_metadata={'selection_epoch':'epoch-a','provenance':{'historical_events':[{'event_id':'source:1','kind':'cleanup_event'}]}})
    second = publish_inventory([row('/historical', 0)], state_dir=tmp_path, now='t2', merge_existing=True,
        merge_policy='existing_wins', scan_metadata={'provenance':{'historical_events':[
            {'event_id':'source:1','kind':'cleanup_event'}, {'event_id':'source:2','kind':'cleanup_summary'}]}})
    current = read_current(tmp_path)
    assert {r['canonical_path'] for r in current['records']} == {'/live','/historical'}
    assert current['manifest']['scan_metadata']['selection_epoch'] == 'epoch-a'
    events = current['manifest']['scan_metadata']['provenance']['historical_events']
    assert [event['event_id'] for event in events] == ['source:1','source:2']


def test_daily_quota_preflights_without_moving_current(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    first = publish_inventory([row('/first', 1)], state_dir=tmp_path, now='2026-10-24T01:00:00Z')
    before = read_current(tmp_path)
    monkeypatch.setattr(codec, 'MAX_DAILY_COMPRESSED_BYTES', first['manifest']['measurement_compressed_bytes'] + 1)
    with pytest.raises(ValueError, match='daily compressed measurement limit'):
        publish_inventory([row('/second', 2)], state_dir=tmp_path, now='2026-10-24T02:00:00Z')
    assert read_current(tmp_path)['pointer'] == before['pointer']


def test_store_high_water_accounts_for_entire_new_graph_before_writing(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    monkeypatch.setattr(codec, 'MAX_STORE_BYTES', 1)
    with pytest.raises(ValueError, match='high-water'):
        publish_inventory([row('/new', 3)], state_dir=tmp_path, now='2026-10-24T00:00:00Z')
    assert not (tmp_path/'inventory'/'current.json').exists()
    assert not list((tmp_path/'inventory'/'objects').glob('*.jsonl.gz'))
    assert list((tmp_path/'inventory'/'objects').glob('.stage-*'))  # bounded 24h grace, never referenced


def test_prune_rejects_symlinked_dependency_before_deleting(tmp_path):
    from datetime import datetime, timedelta, timezone
    from scripts.directory_inventory import prune_retained
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    old = publish_inventory([row('/old', 1)], state_dir=tmp_path, now=start.isoformat())
    publish_inventory([row('/current', 2)], state_dir=tmp_path, now=(start + timedelta(days=91)).isoformat())
    inv = tmp_path / "inventory"
    manifest = old["manifest"]
    object_path = inv / "objects" / (manifest["measurement_manifest_sha256"] + ".jsonl.gz")
    victim = tmp_path / "outside"
    victim.write_text("keep")
    object_path.unlink()
    object_path.symlink_to(victim)
    with pytest.raises(ValueError, match="symlink|escapes"):
        prune_retained(tmp_path, now=start + timedelta(days=92))
    assert victim.read_text() == "keep"


def test_quota_status_unknown_aggregate_is_report_only():
    from scripts.directory_inventory import inventory_quota_status
    result = inventory_quota_status()
    assert result["status"] == "report_only"
    assert result["admission_allowed"] is False
    assert result["reason"] == "aggregate_roots_unknown"
    assert result["physical_bytes"] is None


def test_quota_counts_physical_root_user_spool_and_subledgers(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    roots = {}
    for name in ("root", "user", "spool"):
        roots[name] = tmp_path / name
        roots[name].mkdir()
    (roots["root"] / "inventory" / "indexes").mkdir(parents=True)
    (roots["root"] / "inventory" / "manifests").mkdir()
    (roots["root"] / "inventory" / "indexes" / "index.json").write_bytes(b"x" * 8192)
    (roots["root"] / "inventory" / "manifests" / "m.json").write_bytes(b"y" * 4096)
    (roots["spool"] / "receipt").write_bytes(b"z" * 4096)
    report = codec.inventory_quota_status(aggregate_roots=roots)
    assert report["status"] == "measured" and report["admission_allowed"] is True
    assert report["physical_bytes"] >= 16 * 1024
    assert report["index_bytes"] >= 8 * 1024
    assert report["metadata_grace_bytes"] >= 8 * 1024
    monkeypatch.setattr(codec, "MAX_INDEX_BYTES", 1)
    blocked = codec.inventory_quota_status(aggregate_roots=roots)
    assert blocked["reason"] == "prospective_index_sublimit_exceeded"


def test_quota_rejects_publication_before_any_write_when_aggregate_unknown(tmp_path):
    from scripts.directory_inventory import InventoryAdmissionError
    with pytest.raises(InventoryAdmissionError) as error:
        publish_inventory([row("/blocked", 9)], state_dir=tmp_path, require_admission=True)
    assert error.value.report["reason"] == "aggregate_roots_unknown"
    assert not (tmp_path / "inventory" / "current.json").exists()
    assert not list((tmp_path / "inventory").glob("**/*")) if (tmp_path / "inventory").exists() else True


def test_quota_rejects_aggregate_over_limit_without_advancing_pointer(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    roots = {}
    for name in ("root", "user", "spool"):
        roots[name] = tmp_path / name
        roots[name].mkdir()
    state = roots["user"]
    initial = publish_inventory([row("/initial", 1)], state_dir=state)
    (roots["spool"] / "large").write_bytes(b"x" * 8192)
    monkeypatch.setattr(codec, "MAX_STORE_BYTES", 1024)
    with pytest.raises(codec.InventoryAdmissionError) as error:
        publish_inventory([row("/next", 2)], state_dir=state, require_admission=True,
                          aggregate_roots=roots)
    assert error.value.report["reason"] == "prospective_total_high_water_exceeds_80pct"
    assert read_current(state)["pointer"] == initial["pointer"]


def test_quota_blocks_metadata_and_grace_sublimit(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    roots = {}
    for name in ("root", "user", "spool"):
        roots[name] = tmp_path / name
        roots[name].mkdir()
    inv = roots["user"] / "inventory"
    (inv / "manifests").mkdir(parents=True)
    (inv / "manifests" / "manifest.json").write_bytes(b"m" * 8192)
    (inv / "objects").mkdir()
    (inv / "objects" / "recent.jsonl.gz").write_bytes(b"o" * 8192)
    (inv / ".stage-incomplete").write_bytes(b"s" * 8192)
    monkeypatch.setattr(codec, "MAX_METADATA_BYTES", 1)
    report = codec.inventory_quota_status(aggregate_roots=roots)
    assert report["status"] == "blocked"
    assert report["reason"] == "prospective_metadata_sublimit_exceeded"
    assert report["metadata_grace_bytes"] >= 24 * 1024


def test_nested_fixed_spool_is_counted_once_in_shared_physical_total(tmp_path):
    import scripts.directory_inventory as codec
    root = tmp_path / "root"
    user = tmp_path / "user"
    spool = root / "spool"
    root.mkdir()
    user.mkdir()
    spool.mkdir()
    payload = spool / "receipt"
    payload.write_bytes(b"x" * 16384)
    report = codec.inventory_quota_status(aggregate_roots={
        "root": root, "user": user, "spool": spool})
    assert report["status"] == "measured" and report["admission_allowed"] is True, report
    physical = payload.stat().st_blocks * 512
    assert report["physical_bytes"] == physical
    assert report["metadata_grace_bytes"] == physical


def test_quota_counts_hardlinked_file_once_within_domain(tmp_path):
    import scripts.directory_inventory as codec
    roots = {}
    for name in ("root", "user", "spool"):
        roots[name] = tmp_path / name
        roots[name].mkdir()
    first = roots["user"] / "first"
    first.write_bytes(b"x" * 16384)
    (roots["user"] / "second").hardlink_to(first)
    report = codec.inventory_quota_status(aggregate_roots=roots)
    physical = first.stat().st_blocks * 512
    assert report["status"] == "measured", report
    assert report["domains"]["user"]["physical_bytes"] == physical



def test_publication_external_sort_accepts_one_shot_generator_and_cleans_spool(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    monkeypatch.setattr(codec, "MAX_CHUNK_RAW_BYTES", 512)
    def source():
        for name in ("/z", "/m", "/a"):
            yield row(name, 5)
    result = publish_inventory(source(), state_dir=tmp_path, complete=True)
    assert result["records_count"] == 3
    loaded = read_current(tmp_path)
    assert [item["canonical_path"] for item in loaded["records"]] == ["/a", "/m", "/z"]
    assert not list((tmp_path / "inventory").glob("inventory-sort-*"))


def test_iterator_reader_streams_all_chunk_records(tmp_path):
    from scripts.directory_inventory import iter_current_records, iter_publication_records
    result = publish_inventory((row(f"/stream/{i:03d}", i) for i in range(75)),
                              state_dir=tmp_path, complete=True)
    by_sha = iter_publication_records(tmp_path, result["pointer"]["manifest_sha256"])
    assert len(list(by_sha)) == 75
    assert len(list(iter_current_records(tmp_path))) == 75

def test_compressible_universe_over_32_mib_is_not_rejected_by_raw_size_cap(tmp_path):
    count = 56000
    def records():
        for index in range(count):
            yield row(f"/universe/{index:05d}-" + ("x" * 600), index)
    publication = publish_inventory(records(), state_dir=tmp_path, complete=True)
    manifest = publication["manifest"]
    assert manifest["measurement_bytes"] > 32 * 1024 * 1024
    assert manifest["complete"] is True
    chunks = manifest["chunks"]
    assert len(chunks) > 1
    assert all(chunk["measurement_raw_bytes"] <= 1024 * 1024 for chunk in chunks)
    assert sum(chunk["row_count"] for chunk in chunks) == count
    loaded = read_current(tmp_path)
    assert len(loaded["records"]) == count


def test_merge_publication_uses_ordered_stream_without_compat_list_reader(tmp_path, monkeypatch):
    import scripts.directory_inventory as codec
    publish_inventory([row("/a", 1), row("/c", 3)], state_dir=tmp_path, complete=True)
    def forbidden_list_reader(*args, **kwargs):
        raise AssertionError("merge must not materialize read_current compatibility list")
    monkeypatch.setattr(codec, "read_current", forbidden_list_reader)
    result = codec.publish_inventory((row(path, size) for path, size in (("/b", 2),)),
        state_dir=tmp_path, complete=True, merge_existing=True, merge_policy="incoming_wins")
    assert result["records_count"] == 3
    assert [item["canonical_path"] for item in codec.iter_current_records(tmp_path)] == ["/a", "/b", "/c"]
