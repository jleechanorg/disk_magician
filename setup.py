from pathlib import Path
import shutil
from setuptools import setup
from setuptools.command.build_py import build_py as _build_py

CANONICAL_PATTERNS = (
    "disk_magician.sh",
    "config.json.template",
    "config/*.txt",
    "scripts/*.sh",
    "scripts/*.py",
    "scripts/*.swift",
    "scripts/lib/*.sh",
    "launchd/*.plist",
    "launchd/*.plist.template",
    "launchd/*.c",
    "tools/*.sh",
    "tools/guards/*",
    "hooks/*.sh",
    "systemd/*.template",
    "templates/systemd/*.template",
    "templates/polkit/*.template",
)


class build_py(_build_py):
    """Copy canonical root scripts/templates into build_lib/disk_magician at build time."""

    def run(self):
        super().run()
        if self.editable_mode:
            return
        repo_root = Path(__file__).resolve().parent
        dest_root = Path(self.build_lib) / "disk_magician"
        for pattern in CANONICAL_PATTERNS:
            for src in sorted(repo_root.glob(pattern)):
                if not src.is_file():
                    continue
                rel = src.relative_to(repo_root)
                dest = dest_root / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dest)


setup(cmdclass={"build_py": build_py})
