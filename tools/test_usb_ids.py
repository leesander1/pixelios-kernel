#!/usr/bin/env python3
"""Host test for tools/usb-ids: sysfs and IORegistry listings give the same `ID vvvv:pppp` lines; --has matches the vendor only."""
import importlib.machinery, importlib.util, os, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_loader("usb_ids", importlib.machinery.SourceFileLoader("usb_ids", os.path.join(HERE, "usb-ids")))
usb_ids = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(usb_ids)


class T(unittest.TestCase):
    def test_sysfs(self):
        with tempfile.TemporaryDirectory() as d:
            for name, v, p in (("1-1", "18d1", "4EE0"), ("2-1", "1209", "0001")):
                os.makedirs(os.path.join(d, name))
                open(os.path.join(d, name, "idVendor"), "w").write(v + "\n")
                open(os.path.join(d, name, "idProduct"), "w").write(p + "\n")
            os.makedirs(os.path.join(d, "1-1:1.0"))  # an interface dir: no idVendor, skipped
            self.assertEqual(usb_ids.ids_sysfs(d), [("18d1", "4ee0"), ("1209", "0001")])
        self.assertEqual(usb_ids.ids_sysfs("/nonexistent"), [])

    def test_ioreg(self):
        devs = [{"idVendor": 0x18d1, "idProduct": 0x4ee0, "USB Serial Number": "SECRET"}, {"idVendor": 0x1209, "idProduct": 1}, {"IOObjectClass": "x"}]
        self.assertEqual(usb_ids.ids_ioreg(devs), [("18d1", "4ee0"), ("1209", "0001")])

    def test_has_and_lines(self):
        orig = usb_ids.ids
        usb_ids.ids = lambda: [("18d1", "4ee0")]
        try:
            self.assertEqual(usb_ids.main(["--has", "18D1"]), 0)
            self.assertEqual(usb_ids.main(["--has", "05ac"]), 1)
            self.assertEqual(usb_ids.main(["--bogus"]), 2)
        finally:
            usb_ids.ids = orig


if __name__ == "__main__":
    unittest.main()
