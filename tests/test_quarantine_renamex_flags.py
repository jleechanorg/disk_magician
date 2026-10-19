import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import quarantine_rename as q  # noqa: E402


class RenamexFlagsTest(unittest.TestCase):
    """CodeRabbit #209: the forced-symbol branch must not hand Linux
    renameat2 flag 4 (RENAME_WHITEOUT); it must use 1 (RENAME_NOREPLACE)."""

    def test_forced_renameat2_uses_noreplace(self):
        self.assertEqual(q.renamex_candidates("renameat2"), (("renameat2", 1),))

    def test_forced_renameatx_np_uses_excl(self):
        self.assertEqual(q.renamex_candidates("renameatx_np"), (("renameatx_np", 4),))

    def test_unknown_forced_symbol_yields_no_candidate(self):
        # Fail closed: an arbitrary libc symbol (e.g. non-exclusive `renameat`)
        # must never be attempted with an exclusive flag.
        self.assertEqual(q.renamex_candidates("renameat"), ())
        self.assertEqual(q.renamex_candidates("no_such_symbol"), ())

    def test_default_order_prefers_macos_then_linux(self):
        self.assertEqual(
            q.renamex_candidates(),
            (("renameatx_np", 4), ("renameat2", 1)),
        )

    def test_linux_flag_is_one(self):
        # Guard the constant itself: 4 on Linux is RENAME_WHITEOUT.
        self.assertEqual(q.RENAME_FLAGS["renameat2"], 1)
        self.assertEqual(q.RENAME_FLAGS["renameatx_np"], 4)


if __name__ == "__main__":
    unittest.main()
