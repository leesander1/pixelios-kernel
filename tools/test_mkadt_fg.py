import os
import struct
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from tools import adt, mkadt  # noqa: E402


def node_props(board, name):
    root = adt.parse(adt.serialize(mkadt.build(seed=b"\0" * 64, board=board)))[0]
    for c in root.children:
        p = dict((k, v) for k, _f, v in c.props)
        if p["name"] == name.encode() + b"\0":
            return p
    return None


class SweetFg(unittest.TestCase):
    """xnu patch 0156 (bsd/dev/sweet_fg_gs101.c) reads every address from /sweet-fg; the values are the cited ones in soc.json / board.json."""

    def test_oriole_node(self):
        p = node_props("oriole", "sweet-fg")
        self.assertIsNotNone(p)
        self.assertEqual(p["compatible"], b"google,gs101-max77759-fg\0")
        self.assertEqual(p["reg"], mkadt.u64(0x10D50000, 0x1000))
        self.assertEqual(p["usi-mode-reg"], mkadt.u64(0x10C21010))
        self.assertEqual(struct.unpack("<I", p["usi-mode-i2c"])[0], 0x4)
        self.assertEqual(struct.unpack("<I", p["usi-mode-mask"])[0], 0x7)
        self.assertEqual(struct.unpack("<I", p["usi-regs-offset"])[0], 0xC0)
        self.assertEqual(struct.unpack("<I", p["i2c-addr"])[0], 0x36)
        self.assertEqual(p["pin-scl"], mkadt.u64(0x10C40060, 4))
        self.assertEqual(p["pin-sda"], mkadt.u64(0x10C40060, 5))
        self.assertEqual(p["cmu-reg"], mkadt.u64(0x10C00000, 0x10000))
        self.assertEqual(struct.unpack("<10I", p["cmu-usi"]), (0x800, 0x600, 0x650, 0x654, 0x1810, 0x2030, 0x2050, 0x206C, 0x3030, 21))
        self.assertEqual(struct.unpack("<I", p["chg-i2c-addr"])[0], 0x69)

    def test_only_boards_that_name_it(self):
        self.assertIsNone(node_props("bluejay", "sweet-fg"))
        self.assertIsNone(node_props("sweet", "sweet-fg"))


if __name__ == "__main__":
    unittest.main()
