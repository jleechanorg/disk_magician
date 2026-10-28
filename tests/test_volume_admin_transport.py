import contextlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
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
    argv = volume.linux_docker_helper_argv(
        "/usr/bin/docker", image_id, runtime, "install",
        Path("/home/user/.config/disk-magician/linux-scratch.json"),
        Path("/home/user/.disk_magician_state"), "1000",
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
    assert "volume fstab install scratch" in joined
    assert "--execute" in joined


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
            "writer_pids": [2353264], "image": "/image", "mountpoint": "/mount"}
    privileged = dict(host, writer_pids=[2353265])
    with mock.patch.object(volume, "linux_assert_admin_view", wraps=volume.linux_assert_admin_view):
        try:
            volume.linux_assert_admin_view(host, privileged)
        except RuntimeError as error:
            assert "writer_pids" in str(error)
        else:
            raise AssertionError("mismatched privileged PID view was accepted")


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


def test_docker_migration_requires_digest_before_any_service_stop():
    with mock.patch.object(volume, "linux_command") as command:
        assert volume.linux_service_migrate_cmd([
            "scratch", "--backend", "native", "--config", "/c", "--state-dir", "/s",
            "--user-uid", "1000", "--admin-transport", "docker", "--execute",
        ]) == 2
    command.assert_not_called()
