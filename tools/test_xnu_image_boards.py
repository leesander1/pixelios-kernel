"""XNU image path per board (no kernel, no build, no phone): oriole's ADT differs from bluejay's only in identity,
mkpayload accepts every board, build-xnu-image.sh needs an explicit ADT for any board but bluejay."""
import os, subprocess, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from tools import adt, boards, mkadt  # noqa: E402

SH = os.path.join(HERE, 'build-xnu-image.sh')


def flat(n, path=''):
    """{'/device-tree/chosen:dram-size': value, ...} for a whole parsed ADT"""
    name = dict((k, v) for k, _f, v in n.props).get('name', b'?').rstrip(b'\0').decode()
    p = path + '/' + name
    out = {p + ':' + k: v for k, _f, v in n.props}
    for c in n.children:
        out.update(flat(c, p))
    return out


def tree(board):
    return flat(adt.parse(adt.serialize(mkadt.build(seed=b'\0' * 64, board=board)))[0])


class Boards(unittest.TestCase):
    def test_oriole_differs_from_bluejay_only_in_identity(self):
        a, b = tree('bluejay'), tree('oriole')
        diff = {k for k in set(a) | set(b) if a.get(k) != b.get(k)}
        allowed = {'/device-tree:model-number', '/device-tree/product:product-description'}
        self.assertTrue(diff <= allowed, sorted(diff - allowed))
        self.assertEqual(b['/device-tree:model-number'], b'oriole\0')
        if '/device-tree/product:product-description' in b:   # only with the Apple-derived d22ap.adt present
            self.assertEqual(b['/device-tree/product:product-description'], boards.device_name('oriole').encode() + b'\0')

    def test_bluejay_identity_unchanged(self):
        self.assertEqual(tree('bluejay')['/device-tree:model-number'], b'bluejay\0')

    def test_mkpayload_accepts_every_board(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, 'mkpayload.py'), '-h'], capture_output=True, text=True)
        for b in boards.BOARDS:
            self.assertIn(b, r.stdout)

    def test_build_xnu_image_needs_adt_off_bluejay(self):
        env = dict(os.environ, XNU_IMAGE_ARGS_ONLY='1')
        env.pop('PIXOS_DEVICE', None)
        r = subprocess.run(['bash', SH, '--board', 'oriole'], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn('needs --adt', r.stderr)
        r = subprocess.run(['bash', SH, '--board', 'oriole', '--adt', '/dev/null'], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)   # stops at the args-only hook, before mkpayload
        r = subprocess.run(['bash', SH], capture_output=True, text=True, env=dict(env, PIXOS_DEVICE='oriole'))
        self.assertEqual(r.returncode, 2, r.stderr)   # PIXOS_DEVICE picks the board too


if __name__ == '__main__':
    unittest.main()
