#!/usr/bin/env python3
"""Host test for tools/fflash-userdata.sh with a stub fastboot (no phone): every refusal fires before `fastboot flash`, and the
one accepted case flashes exactly the target phone. The real lock tool runs on a temp lock dir; the flash record is a temp file."""
import hashlib, os, shutil, stat, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, 'fflash-userdata.sh')
FASTBOOT = '''#!/bin/bash
echo "$*" >> "$ST_LOG"
case "$1 $2" in
	"getvar product") echo "product: ${ST_PROD:-oriole}" >&2 ;;
	"getvar unlocked") echo "unlocked: ${ST_UNL:-yes}" >&2 ;;
	"flash userdata") echo "Sending sparse 'userdata' 1/1 (4 KB)"; echo "Finished." ;;
esac
'''


class FlashUserdata(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix='fflash_test_')
        self.addCleanup(shutil.rmtree, self.d, True)
        bindir = os.path.join(self.d, 'bin'); os.mkdir(bindir)
        fb = os.path.join(bindir, 'fastboot')
        with open(fb, 'w') as f:
            f.write(FASTBOOT)
        os.chmod(fb, os.stat(fb).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.d, 'fastboot.log')
        self.env = dict(os.environ, PATH=bindir + ':' + os.environ['PATH'], ST_LOG=self.log,
                        PHONE_LOCK_DIR=os.path.join(self.d, 'lock'), PHONE_LOCK_TOKEN='ff-token',
                        FLASH_STATE=os.path.join(self.d, 'flashed.txt'))
        self.env.pop('PIXOS_DEVICE', None)
        subprocess.run([os.path.join(HERE, 'phone-lock'), 'acquire', '--owner', 'ff-test', '--token', 'ff-token'],
                       env=self.env, capture_output=True, check=True)
        self.img = self.image('root.img', b'\x00' * 4096 + b'HX' + b'\x00' * 4094)

    def image(self, name, data=None, size=None):
        p = os.path.join(self.d, name)
        with open(p, 'wb') as f:
            if data is not None:
                f.write(data)
            else:
                f.truncate(size)       # sparse: the size check must refuse it before anything reads it
        h = hashlib.sha256(data).hexdigest() if data is not None else '0' * 64
        with open(p + '.sha256', 'w') as f:
            f.write(f'{h}  {name}\n')
        return p

    def run_tool(self, *args, **env):
        if os.path.exists(self.log):
            os.remove(self.log)
        return subprocess.run(['bash', TOOL, *args], env=dict(self.env, **env), capture_output=True, text=True, timeout=120)

    def flashed(self):
        if not os.path.exists(self.log):
            return False
        with open(self.log) as f:
            return 'flash userdata' in f.read()

    def test_target_phone_is_flashed_once(self):
        r = self.run_tool(self.img, '--yes-erase-userdata', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.flashed())
        r = self.run_tool(self.img, '--yes-erase-userdata', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 1); self.assertIn('already flashed', r.stderr); self.assertFalse(self.flashed())
        r = self.run_tool(self.img, '--yes-erase-userdata', '--force', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 0, r.stderr); self.assertTrue(self.flashed())

    def test_refusals_never_flash(self):
        big = self.image('big.img', size=(112914 + 1) * 1048576)
        bad = self.image('bad.img', b'\x01' * 4096)
        with open(bad + '.sha256', 'w') as f:
            f.write('0' * 64 + '  bad.img\n')
        cases = [
            ('no confirmation flag', (self.img,), dict(PIXOS_DEVICE='oriole'), 1, 'erases userdata'),
            ('a 6a attached, target oriole', (self.img, '--yes-erase-userdata'), dict(PIXOS_DEVICE='oriole', ST_PROD='bluejay'), 1, "product='bluejay'"),
            ('a Pixel 6 attached, default target', (self.img, '--yes-erase-userdata'), dict(ST_PROD='oriole'), 1, "product='oriole'"),
            ('locked bootloader', (self.img, '--yes-erase-userdata'), dict(PIXOS_DEVICE='oriole', ST_UNL='no'), 1, "unlocked='no'"),
            ('image bigger than userdata', (big, '--yes-erase-userdata'), dict(PIXOS_DEVICE='oriole'), 1, 'userdata partition is 112914 MiB'),
            ('hash mismatch', (bad, '--yes-erase-userdata'), dict(PIXOS_DEVICE='oriole'), 1, 'does not match'),
            ('unsupported phone', (self.img, '--yes-erase-userdata'), dict(PIXOS_DEVICE='raven'), 2, 'not a supported phone'),
        ]
        for name, args, env, rc, msg in cases:
            with self.subTest(name):
                r = self.run_tool(*args, **env)
                self.assertEqual(r.returncode, rc, r.stderr)
                self.assertIn(msg, r.stderr)
                self.assertFalse(self.flashed())

    @unittest.skipUnless(shutil.which('img2simg') and shutil.which('simg2img'), 'needs img2simg/simg2img (brew install simg2img)')
    def test_sparse_flashes_the_checked_simg(self):
        img = self.image('s.img', os.urandom(4096) + b'\0' * 4096 * 3 + b'\x5a' * 4096)
        r = self.run_tool(img, '--yes-erase-userdata', '--sparse', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('sparse ok: both readers reproduce', r.stderr)
        with open(self.log) as f:
            self.assertIn('flash userdata ' + img + '.simg', f.read())

    @unittest.skipUnless(shutil.which('simg2img'), 'needs simg2img')
    def test_sparse_with_dont_care_is_refused(self):
        """MUTANT converter: the zero run becomes DONT_CARE (old partition data would survive) -> refused, nothing flashed"""
        conv = os.path.join(self.d, 'bin', 'img2simg')
        with open(conv, 'w') as f:
            f.write('#!/bin/sh\nexec python3 -c "import sys; sys.path.insert(0, %r); import sparse_check as s; '
                    'd = open(sys.argv[1], \'rb\').read(); '
                    's.write(sys.argv[2], [(s.RAW, 1, d[:4096]), (s.DONT_CARE, len(d) // 4096 - 1, b\'\')])" "$1" "$2"\n' % HERE)
        os.chmod(conv, 0o755)
        img = self.image('m.img', os.urandom(4096) + b'\0' * 4096 * 3)
        r = self.run_tool(img, '--yes-erase-userdata', '--sparse', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn('DONT_CARE', r.stderr)
        self.assertFalse(self.flashed())

    def test_no_lock_no_flash(self):
        subprocess.run([os.path.join(HERE, 'phone-lock'), 'release', '--token', 'ff-token'], env=self.env, capture_output=True, check=True)
        r = self.run_tool(self.img, '--yes-erase-userdata', PIXOS_DEVICE='oriole')
        self.assertEqual(r.returncode, 1); self.assertIn('phone lock', r.stderr); self.assertFalse(self.flashed())


if __name__ == '__main__':
    unittest.main()
