import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
from types import SimpleNamespace
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("volume_admin_transport", ROOT / "scripts" / "volume.py")
volume = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = volume
SPEC.loader.exec_module(volume)


def test_docker_helper_argv_is_fixed_and_narrow(tmp_path):
    image_id = "sha256:" + "a" * 64
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    (runtime / "disk_magician.sh").write_text("#!/bin/sh\n")
    (runtime / "scripts").mkdir()
    helper = runtime / "scripts/volume.py"
    helper.write_text("# verified fixture\n")
    manifest = {"package_root": str(runtime), "package_hashes": {
        "scripts/volume.py": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "disk_magician.sh": hashlib.sha256((runtime / "disk_magician.sh").read_bytes()).hexdigest(),
    }}
    argv = volume.linux_docker_helper_argv(
        "/usr/bin/docker", image_id, runtime, "install",
        Path("/home/user/.config/disk-magician/linux-scratch.json"),
        Path("/home/user/.disk_magician_state"), "1000", manifest["package_hashes"]["scripts/volume.py"], manifest,
    )
    joined = " ".join(argv)
    assert "--host unix:///var/run/docker.sock" in joined
    assert "--pull never" in joined
    assert "--network none" in joined
    assert "--pid host" in joined
    assert "--security-opt apparmor=unconfined" in joined
    assert "--cap-drop ALL" in joined
    assert "--cap-add SYS_CHROOT" in joined
    assert "--cap-add DAC_OVERRIDE" in joined
    assert "--cap-add SYS_PTRACE" in joined
    assert "--read-only" in joined
    assert "type=bind,src=/,dst=/host,readonly" in joined
    assert "type=bind,src=/etc,dst=/host/etc" in joined
    assert "--privileged" not in argv
    assert "/usr/bin/bash" not in " ".join(argv)
    assert "exec chroot /host" not in " ".join(argv)
    assert ["--entrypoint", "/usr/sbin/chroot"] == argv[argv.index("--entrypoint"):argv.index("--entrypoint") + 2]
    assert "/usr/bin/python3" in argv
    compile(argv[-1], "<fixed-admin-bootstrap>", "exec")
    assert '"fstab","install","scratch"' in joined
    assert "--execute" in joined


def test_generated_bootstrap_copies_manifest_and_executes_verified_helper(tmp_path):
    runtime = tmp_path / "runtime"
    scripts = runtime / "scripts"
    scripts.mkdir(parents=True)
    launcher = runtime / "disk_magician.sh"
    launcher.write_text("#!/bin/sh\nexit 99\n")
    dependency = scripts / "dep.py"
    dependency.write_text("MARKER = 'verified-dependency'\n")
    helper = scripts / "volume.py"
    helper.write_text(
        "import json, sys\nfrom dep import MARKER\n"
        "print(json.dumps({'argv': sys.argv[1:], 'marker': MARKER}))\n"
    )
    manifest = {"package_root": str(runtime), "package_hashes": {
        "scripts/dep.py": hashlib.sha256(dependency.read_bytes()).hexdigest(),
        "scripts/volume.py": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "disk_magician.sh": hashlib.sha256(launcher.read_bytes()).hexdigest(),
    }}
    argv = volume.linux_docker_helper_argv(
        "/usr/bin/docker", "sha256:" + "a" * 64, runtime, "probe",
        Path("/home/user/config"), Path("/home/user/state"), "1000",
        manifest["package_hashes"]["scripts/volume.py"], manifest,
    )
    bootstrap = argv[-1]
    snapshots = [tmp_path / "snapshot-1", tmp_path / "snapshot-2"]
    for snapshot in snapshots:
        snapshot.mkdir()
    snapshot_iter = iter(snapshots)
    original_cwd, original_argv = os.getcwd(), sys.argv[:]

    def allocate_snapshot(*_args, **_kwargs):
        return str(next(snapshot_iter))

    try:
        with (
            mock.patch.object(volume.tempfile, "mkdtemp", side_effect=allocate_snapshot),
            contextlib.redirect_stdout(io.StringIO()) as first_output,
        ):
            exec(bootstrap, {"__name__": "__main__"})
        first = json.loads(first_output.getvalue())
        assert first["marker"] == "verified-dependency"
        assert first["argv"][0:3] == ["fstab", "probe", "scratch"]
        assert "--runtime-sha256" in first["argv"]

        dependency.write_text("MARKER = 'tampered'\n")
        with (
            mock.patch.object(volume.tempfile, "mkdtemp", side_effect=allocate_snapshot),
            contextlib.redirect_stdout(io.StringIO()) as second_output,
        ):
            try:
                exec(bootstrap, {"__name__": "__main__"})
            except SystemExit as error:
                assert error.code == 75
            else:
                raise AssertionError("tampered dependency was accepted")
        assert second_output.getvalue() == ""
    finally:
        os.chdir(original_cwd)
        sys.argv[:] = original_argv


def test_docker_probe_keeps_host_etc_read_only(tmp_path):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    (runtime / "disk_magician.sh").write_text("#!/bin/sh\n")
    (runtime / "scripts").mkdir()
    helper = runtime / "scripts/volume.py"
    helper.write_text("# verified fixture\n")
    manifest = {"package_root": str(runtime), "package_hashes": {
        "scripts/volume.py": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "disk_magician.sh": hashlib.sha256((runtime / "disk_magician.sh").read_bytes()).hexdigest(),
    }}
    argv = volume.linux_docker_helper_argv(
        "/usr/bin/docker", "sha256:" + "a" * 64, runtime, "probe",
        Path("/c"), Path("/s"), "1000", manifest["package_hashes"]["scripts/volume.py"], manifest,
    )
    assert "type=bind,src=/etc,dst=/host/etc" not in argv


def test_docker_transport_rejects_rootless_daemon():
    socket_stat = mock.Mock(st_mode=stat.S_IFSOCK, st_uid=0)
    info = json.dumps({"Rootless": True, "DockerRootDir": "/var/lib/docker",
                       "SecurityOptions": ["name=rootless"]}).encode()
    with (
        mock.patch.object(volume, "DOCKER_SOCKET", mock.Mock(lstat=lambda: socket_stat)),
        mock.patch.object(volume.shutil, "which", return_value="/usr/bin/docker"),
        mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=info, stderr=b"")),
    ):
        try:
            volume.linux_docker_transport_info("sha256:" + "a" * 64)
        except ValueError as error:
            assert "rootless" in str(error)
        else:
            raise AssertionError("rootless Docker transport was accepted")


def test_docker_transport_accepts_only_local_fixed_rootful_image():
    image_id = "sha256:" + "b" * 64
    socket_stat = mock.Mock(st_mode=stat.S_IFSOCK, st_uid=0)
    info = json.dumps({"Rootless": False, "DockerRootDir": "/var/lib/docker",
                       "SecurityOptions": []})
    calls = [
        mock.Mock(returncode=0, stdout=info, stderr=""),
        mock.Mock(returncode=0, stdout=image_id + "\n", stderr=""),
    ]
    with (
        mock.patch.object(volume, "DOCKER_SOCKET", mock.Mock(lstat=lambda: socket_stat)),
        mock.patch.object(volume.shutil, "which", return_value="/usr/bin/docker"),
        mock.patch.object(volume.subprocess, "run", side_effect=calls) as run,
    ):
        docker, details = volume.linux_docker_transport_info(image_id)
    assert docker == "/usr/bin/docker"
    assert details["DockerRootDir"] == "/var/lib/docker"
    assert run.call_args_list[0].args[0][:4] == ["/usr/bin/docker", "--host", "unix:///var/run/docker.sock", "info"]
    assert run.call_args_list[1].args[0][:5] == ["/usr/bin/docker", "--host", "unix:///var/run/docker.sock", "image", "inspect"]


def test_admin_view_rejects_pid_or_mount_equivalence_mismatch():
    host = {"mount": ["fuse.ext4", "/dev/loop7"], "loop_devices": ["/dev/loop7"],
            "writer_pids": [2353264], "reader_pids": [2353264], "image": "/image", "mountpoint": "/mount"}
    privileged = dict(host, writer_pids=[2353265])
    with mock.patch.object(volume, "linux_assert_admin_view", wraps=volume.linux_assert_admin_view):
        try:
            volume.linux_assert_admin_view(host, privileged)
        except RuntimeError as error:
            assert "writer_pids" in str(error)
        else:
            raise AssertionError("mismatched privileged PID view was accepted")


def test_host_tuple_probe_json_roundtrip_matches_docker_view(tmp_path):
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    with (
        mock.patch.object(volume, "linux_fuser_pid_set", side_effect=[{17}, {17}]),
        mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", "/dev/loop7")),
        mock.patch.object(volume, "linux_loop_devices", return_value=[Path("/dev/loop7")]),
    ):
        host = volume.linux_host_fstab_probe(image, mountpoint)
    privileged = json.loads(json.dumps(host))
    volume.linux_assert_admin_view(host, privileged)
    assert host["mount"] == ["fuse.ext4", "/dev/loop7"]


def test_fuser_unexpected_diagnostics_fail_closed():
    with mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(
        returncode=0, stdout=b" 2353264\n", stderr=b"warning 28\n")):
        assert volume.linux_fuser_pid_set(Path("/image"), writers_only=True) is None


def test_fuser_accepts_only_numeric_stdout_with_exact_path_stderr():
    with mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(
        returncode=0, stdout=b" 17 29\n", stderr=b"/image:\n")):
        assert volume.linux_fuser_pid_set(Path("/image"), writers_only=True) == {17, 29}


def test_deployed_runtime_manifest_binds_helper_source(tmp_path):
    runtime = tmp_path / "package"
    scripts = runtime / "scripts"
    scripts.mkdir(parents=True)
    helper = scripts / "volume.py"
    orchestrator = runtime / "disk_magician.sh"
    helper.write_text("canonical helper\n")
    orchestrator.write_text("#!/bin/sh\n")
    hashes = {
        "scripts/volume.py": hashlib.sha256(helper.read_bytes()).hexdigest(),
        "disk_magician.sh": hashlib.sha256(orchestrator.read_bytes()).hexdigest(),
    }
    state = tmp_path / "state"
    state.mkdir()
    (state / "deployed.json").write_text(json.dumps({
        "schema_version": 1, "package_root": str(runtime), "package_hashes": hashes,
    }))
    assert volume.linux_validate_installed_runtime(runtime, state) == hashes["scripts/volume.py"]
    helper.write_text("tampered\n")
    try:
        volume.linux_validate_installed_runtime(runtime, state)
    except ValueError as error:
        assert "hash" in str(error)
    else:
        raise AssertionError("tampered deployed helper was accepted")


def test_admin_view_rejects_missing_or_unknown_reader_set():
    host = {"mount": ["fuse.ext4", "/dev/loop7"], "loop_devices": ["/dev/loop7"],
            "writer_pids": [2353264], "reader_pids": [2353264], "image": "/image", "mountpoint": "/mount"}
    for privileged in ({k: v for k, v in host.items() if k != "reader_pids"},
                       dict(host, reader_pids=None)):
        try:
            volume.linux_assert_admin_view(host, privileged)
        except RuntimeError:
            pass
        else:
            raise AssertionError("incomplete admin view was accepted")


def test_fstab_probe_is_canonical_read_only_action():
    view = {"mount": None, "loop_devices": [], "writer_pids": [17], "reader_pids": [17],
            "image": "/image", "mountpoint": "/mount"}
    output = io.StringIO()
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(Path("/c"), Path("/s"), Path("/i"), Path("/m"))),
        mock.patch.object(volume, "linux_host_fstab_probe", return_value=view),
        contextlib.redirect_stdout(output),
    ):
        assert volume.main(["fstab", "probe", "scratch", "--config", "/c", "--state-dir", "/s", "--user-uid", "1000"]) == 0
    assert json.loads(output.getvalue())["probe"] == "fstab"


def test_probe_allowed_paths_accepts_mountinfo_without_relaxing_mutation_paths(tmp_path):
    home = tmp_path
    config = home / ".config/disk-magician/linux-scratch.json"
    state = home / ".disk_magician_state"
    image = home / ".local/share/disk-magician/volumes/scratch.ext4"
    mountpoint = home / "Scratch"
    config.parent.mkdir(parents=True)
    state.mkdir()
    image.parent.mkdir(parents=True)
    image.write_bytes(b"fixture")
    config.write_text(json.dumps({"volumes": {"classes": {"scratch": {
        "image_path": str(image), "mountpoint": str(mountpoint), "backend": "fuse",
    }}}}))
    uid = os.getuid()
    with (
        mock.patch.object(volume.pwd, "getpwuid", return_value=SimpleNamespace(pw_dir=str(home))),
        mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", str(image))),
    ):
        probe_safe = volume.linux_fstab_allowed_paths(
            str(config), str(state), str(uid), None, probe_mounted=True
        )
        strict_safe = volume.linux_fstab_allowed_paths(str(config), str(state), str(uid), None)
    assert probe_safe == (config, state, image, mountpoint)
    assert strict_safe is None


def test_fsck_refuses_active_service_before_e2fsck():
    image = Path("/home/user/.local/share/disk-magician/volumes/scratch.ext4")
    mountpoint = Path("/home/user/Scratch")
    settings = {"classes": {"scratch": {"quota_gb": 2}}}
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 2}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(Path("/c"), Path("/s"), image, mountpoint)),
        mock.patch.object(volume.os, "geteuid", return_value=1000),
        mock.patch.object(volume, "cls", return_value=(settings, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume.Path, "stat", return_value=mock.Mock(st_size=2 * volume.GIB, st_uid=1000)),
        mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0)) as run,
    ):
        assert volume.main(["fsck", "scratch", "--config", "/c", "--state-dir", "/s", "--user-uid", "1000"]) == 75
    assert run.call_args.args[0][:4] == ["systemctl", "--user", "is-active", "--quiet"]


def test_fsck_diagnostic_is_separate_and_preserves_raw_exit():
    image = Path("/home/user/.local/share/disk-magician/volumes/scratch.ext4")
    mountpoint = Path("/home/user/Scratch")
    settings = {"classes": {"scratch": {"quota_gb": 2}}}
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 2}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    calls = [mock.Mock(returncode=3), mock.Mock(returncode=1, stdout="needs repair\n", stderr="")]
    output = io.StringIO()
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(Path("/c"), Path("/s"), image, mountpoint)),
        mock.patch.object(volume.os, "geteuid", return_value=1000),
        mock.patch.object(volume, "cls", return_value=(settings, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume.Path, "stat", return_value=mock.Mock(st_size=2 * volume.GIB, st_uid=1000)),
        mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume, "linux_mount_record", return_value=None),
        mock.patch.object(volume, "linux_loop_devices", return_value=[]),
        mock.patch.object(volume, "linux_fuser_pid_set", return_value=set()),
        mock.patch.object(volume.shutil, "which", return_value="/usr/sbin/e2fsck"),
        mock.patch.object(volume.subprocess, "run", side_effect=calls),
        contextlib.redirect_stdout(output),
    ):
        assert volume.main(["fsck", "scratch", "--config", "/c", "--state-dir", "/s", "--user-uid", "1000"]) == 1
    record = json.loads(output.getvalue())
    assert record["raw_exit"] == 1
    assert record["command"][-2:] == ["-fn", str(image)]


def test_fsck_repair_uses_persistent_undo_and_exclusive_receipt(tmp_path):
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    image.write_bytes(b"fixture")
    mountpoint.mkdir()
    uid = os.getuid()
    settings = {"classes": {"scratch": {"quota_gb": 2}}}
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 2}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    original_stat = Path.stat

    def stat_override(path, *args, **kwargs):
        if path == image:
            return mock.Mock(st_size=2 * volume.GIB, st_uid=uid)
        return original_stat(path, *args, **kwargs)

    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[:4] == ["systemctl", "--user", "is-active", "--quiet"]:
            return mock.Mock(returncode=3)
        undo = Path(command[command.index("-z") + 1])
        undo.write_bytes(b"undo")
        return mock.Mock(returncode=0, stdout="clean\n", stderr="")

    output = io.StringIO()
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(tmp_path / "c", tmp_path / "s", image, mountpoint)),
        mock.patch.object(volume.os, "geteuid", return_value=uid),
        mock.patch.object(volume, "cls", return_value=(settings, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume.Path, "stat", new=stat_override),
        mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume, "linux_mount_record", return_value=None),
        mock.patch.object(volume, "linux_loop_devices", return_value=[]),
        mock.patch.object(volume, "linux_fuser_pid_set", return_value=set()),
        mock.patch.object(volume.shutil, "which", return_value="/usr/sbin/e2fsck"),
        mock.patch.object(volume.subprocess, "run", side_effect=run),
        contextlib.redirect_stdout(output),
    ):
        assert volume.main(["fsck", "scratch", "--config", "/c", "--state-dir", "/s",
                            "--user-uid", str(uid), "--repair", "--execute"]) == 0
    assert calls[-1][1:4] == ["-fp", "-z", str(image.with_name("scratch.ext4.e2fsck-undo"))]
    assert image.with_name("scratch.ext4.e2fsck-undo").is_file()
    assert image.with_name("scratch.ext4.e2fsck-undo.receipt.json").is_file()
    assert json.loads(output.getvalue())["undo_path"].endswith(".e2fsck-undo")


def test_fsck_repair_requires_service_already_stopped(tmp_path):
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    image.write_bytes(b"fixture")
    mountpoint.mkdir()
    uid = os.getuid()
    settings = {"classes": {"scratch": {"quota_gb": 2}}}
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 2}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    unit = tmp_path / ".config/systemd/user/diskm-scratch.service"
    unit.parent.mkdir(parents=True)
    unit.write_text("verified unit")
    original_stat = Path.stat

    def stat_override(path, *args, **kwargs):
        if path == image:
            return mock.Mock(st_size=2 * volume.GIB, st_uid=uid)
        return original_stat(path, *args, **kwargs)

    service_calls = []

    def run(command, **kwargs):
        if command[:4] == ["systemctl", "--user", "is-active", "--quiet"]:
            return mock.Mock(returncode=0)
        undo = Path(command[command.index("-z") + 1])
        undo.write_bytes(b"undo")
        return mock.Mock(returncode=0, stdout="clean\n", stderr="")

    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(tmp_path / "c", tmp_path / "s", image, mountpoint)),
        mock.patch.object(volume.os, "geteuid", return_value=uid),
        mock.patch.object(volume, "cls", return_value=(settings, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume.Path, "stat", new=stat_override),
        mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume, "linux_mount_record", return_value=None),
        mock.patch.object(volume, "linux_loop_devices", return_value=[]),
        mock.patch.object(volume, "linux_fuser_pid_set", return_value=set()),
        mock.patch.object(volume, "linux_service_matches_fuse_unit", return_value=True),
        mock.patch.object(volume.shutil, "which", return_value="/usr/sbin/e2fsck"),
        mock.patch.object(volume.subprocess, "run", side_effect=run),
        mock.patch.object(volume, "linux_command", side_effect=lambda args, timeout=30: service_calls.append(args)),
        mock.patch.object(volume.Path, "home", return_value=tmp_path),
    ):
        assert volume.main(["fsck", "scratch", "--config", "/c", "--state-dir", "/s",
                            "--user-uid", str(uid), "--repair", "--execute"]) == 75
    assert service_calls == []


def test_fstab_runtime_hash_is_checked_by_real_parser(tmp_path):
    digest = hashlib.sha256(Path(volume.__file__).read_bytes()).hexdigest()
    view = {"mount": None, "loop_devices": [], "writer_pids": [17], "reader_pids": [17],
            "image": "/image", "mountpoint": "/mount", "runtime_sha256": digest}
    output = io.StringIO()
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(Path("/c"), Path("/s"), Path("/i"), Path("/m"))),
        mock.patch.object(volume, "linux_host_fstab_probe", return_value=view),
        contextlib.redirect_stdout(output),
    ):
        assert volume.linux_fstab_cmd("probe", ["scratch", "--config", "/c", "--state-dir", "/s",
                                                  "--user-uid", "1000", "--runtime-sha256", digest]) == 0
        assert volume.linux_fstab_cmd("probe", ["scratch", "--config", "/c", "--state-dir", "/s",
                                                  "--user-uid", "1000", "--runtime-sha256", "0" * 64]) == 75


def test_service_stop_requires_exact_unit_and_explicit_execute(tmp_path):
    config = tmp_path / "linux-scratch.json"
    state = tmp_path / "state"
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    unit = tmp_path / ".config/systemd/user/diskm-scratch.service"
    state.mkdir()
    image.write_bytes(b"fixture")
    mountpoint.mkdir()
    unit.parent.mkdir(parents=True)
    unit.write_text("verified")
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 1}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint)}
    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(config, state, image, mountpoint)),
        mock.patch.object(volume, "cls", return_value=({}, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", str(image))),
        mock.patch.object(volume, "linux_validate_mount"),
        mock.patch.object(volume, "linux_service_matches_fuse_unit", return_value=True),
        mock.patch.object(volume.Path, "home", return_value=tmp_path),
        mock.patch.object(volume.os, "geteuid", return_value=os.getuid()),
        mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0)),
        mock.patch.object(volume, "linux_command") as command,
    ):
        args = ["service", "stop", "scratch", "--config", str(config), "--state-dir", str(state),
                "--user-uid", str(os.getuid()), "--execute"]
        assert volume.main(args) == 0
        command.assert_called_once_with(["systemctl", "--user", "stop", "diskm-scratch.service"], 60)


def test_service_start_from_offline_validates_mount_after_fixed_unit_start(tmp_path):
    config = tmp_path / "linux-scratch.json"
    state = tmp_path / "state"
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    unit = tmp_path / ".config/systemd/user/diskm-scratch.service"
    state.mkdir()
    image.write_bytes(b"fixture")
    mountpoint.mkdir()
    unit.parent.mkdir(parents=True)
    runtime = Path(volume.__file__).resolve().parent.parent
    unit.write_bytes(volume.linux_service_render(runtime, str(config), state, "fuse").encode())
    uid = os.getuid()
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 1}
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    original_stat = Path.stat
    mount_records = [("fuse.ext4", str(image))]

    def stat_override(path, *args, **kwargs):
        if path == image:
            return mock.Mock(st_mode=stat.S_IFREG | 0o600, st_size=volume.GIB, st_uid=uid)
        return original_stat(path, *args, **kwargs)

    def validate_after_start(*_args):
        assert volume.linux_mount_record(mountpoint) is not None

    with (
        mock.patch.object(volume.sys, "platform", "linux"),
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(config, state, image, mountpoint)),
        mock.patch.object(volume, "cls", return_value=({}, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume, "linux_mount_record", side_effect=lambda _path: mount_records.pop(0)),
        mock.patch.object(volume, "linux_validate_mount", side_effect=validate_after_start),
        mock.patch.object(volume.subprocess, "run", side_effect=[mock.Mock(returncode=3), mock.Mock(returncode=0)]),
        mock.patch.object(volume, "linux_command") as command,
        mock.patch.object(volume.Path, "home", return_value=tmp_path),
        mock.patch.object(volume.Path, "stat", new=stat_override),
        mock.patch.object(volume.os, "geteuid", return_value=uid),
    ):
        args = ["service", "start", "scratch", "--config", str(config), "--state-dir", str(state),
                "--user-uid", str(uid), "--execute"]
        assert volume.main(args) == 0
    assert command.call_args_list == [
        mock.call(["systemctl", "--user", "start", "diskm-scratch.service"], 60),
        mock.call(["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"], 15),
    ]


def test_docker_migration_requires_digest_before_any_service_stop():
    with mock.patch.object(volume, "linux_command") as command:
        assert volume.linux_service_migrate_cmd([
            "scratch", "--backend", "native", "--config", "/c", "--state-dir", "/s",
            "--user-uid", "1000", "--admin-transport", "docker", "--execute",
        ]) == 2
    command.assert_not_called()


def test_docker_preflight_failure_does_not_stop_or_rollback(tmp_path):
    config = tmp_path / "linux-scratch.json"
    state = tmp_path / "state"
    image = tmp_path / "scratch.ext4"
    mountpoint = tmp_path / "Scratch"
    runtime = tmp_path / "runtime"
    unit = tmp_path / ".config/systemd/user/diskm-scratch.service"
    state.mkdir()
    mountpoint.mkdir()
    runtime.mkdir()
    (runtime / "disk_magician.sh").write_text("#!/bin/sh\n")
    (runtime / "systemd").mkdir()
    image.write_bytes(b"fixture")
    config.write_text(json.dumps({"volumes": {"classes": {"scratch": {
        "image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 1,
        "backend": "fuse"}}}}))
    unit.parent.mkdir(parents=True)
    unit.write_text("unit")
    entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
             "quota_bytes": volume.GIB, "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
    scratch = {"image_path": str(image), "mountpoint": str(mountpoint), "quota_gb": 1, "backend": "fuse"}
    with (
        mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(config, state, image, mountpoint)),
        mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
        mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
        mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
        mock.patch.object(volume, "linux_service_matches_fuse_unit", return_value=True),
        mock.patch.object(volume, "linux_validate_installed_runtime", return_value={
            "package_root": str(runtime), "package_hashes": {"scripts/volume.py": "a" * 64},
        }),
        mock.patch.object(volume, "linux_docker_transport_info", return_value=("/usr/bin/docker", {})),
        mock.patch.object(volume, "linux_host_fstab_probe", return_value={
            "mount": None, "loop_devices": [], "writer_pids": [17], "reader_pids": [17],
            "image": str(image), "mountpoint": str(mountpoint), "runtime_sha256": "a" * 64,
        }),
        mock.patch.object(volume, "linux_docker_probe", side_effect=RuntimeError("helper view rejected")),
        mock.patch.object(volume, "linux_command") as command,
        mock.patch.object(volume, "linux_atomic_bytes") as atomic,
        mock.patch.object(volume.Path, "home", return_value=tmp_path),
        mock.patch.object(volume, "__file__", str(runtime / "scripts" / "volume.py")),
    ):
        assert volume.linux_service_migrate_cmd([
            "scratch", "--backend", "native", "--config", str(config), "--state-dir", str(state),
            "--user-uid", str(os.getuid()), "--admin-transport", "docker",
            "--admin-image-id", "sha256:" + "a" * 64, "--execute",
        ]) == 75
    command.assert_not_called()
    atomic.assert_not_called()
