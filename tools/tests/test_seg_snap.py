"""Tests for frontend-ios/Shell/App/SegSnap.h and frontend-ios/Shell/project-shell.yml."""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHELL_APP_DIR = ROOT / 'frontend-ios/Shell/App'
PROJECT_SHELL = ROOT / 'frontend-ios/Shell/project-shell.yml'
T_SEG_SNAP_C = Path(__file__).resolve().parent / 't_seg_snap.c'


class ShellProjectPolicyTests(unittest.TestCase):
    def test_phone_and_ipad_orientations_and_no_fullscreen_lock(self):
        source = PROJECT_SHELL.read_text(encoding='utf-8')
        landscape = {'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
        phone = landscape | {'UIInterfaceOrientationPortrait'}
        all_orientations = phone | {'UIInterfaceOrientationPortraitUpsideDown'}
        for key, expected in (('UISupportedInterfaceOrientations', phone),
                              ('UISupportedInterfaceOrientations~ipad', all_orientations)):
            match = re.search(r'^        ' + re.escape(key) + r':[^\n]*\n((?:          - .*\n)+)', source, re.MULTILINE)
            self.assertIsNotNone(match, f'Missing orientation array: {key}')
            self.assertEqual(set(re.findall(r'- (\w+)', match[1])), expected)
        self.assertNotIn('UIRequiresFullScreen:', source)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'needs macOS clang')
class MachOSegSnapTests(unittest.TestCase):
    """Compile a real Mach-O dylib whose __DATA,__bss has an unaligned size and initial non-zero tail, plus t_seg_snap.c."""

    DYLIB_C = """\
    #include <stdint.h>
    #include <string.h>

    __attribute__((used, visibility("default")))
    const char dmgame_image_marker[] = "DmGame";

    // Static zero-initialized storage goes into __DATA,__bss on Mach-O with an odd total size
    // (32771 B) so both multi-page zeroing and unaligned tail bytes are exercised on a real dylib.
    __attribute__((aligned(1), used))
    static uint8_t g_bss_blob[32771];

    static int g_data_val = 0x13572468;

    __attribute__((used, visibility("default")))
    uint8_t *get_bss_blob(void) {
        return g_bss_blob;
    }

    __attribute__((constructor))
    static void init_bss_before_snapshot(void) {
        uint8_t *p = g_bss_blob;
        __asm__ volatile("" : "+r"(p));
        p[0] = 0xA7;
        p[1] = 0x5B;
        p[16] = 0x42;
        p[32768] = 0xC3;
        p[32769] = 0xD4;
        p[32770] = 0xE5;
    }

    __attribute__((used, visibility("default")))
    void mutate_game_state(void) {
        g_data_val = 99;
        memset(g_bss_blob, 0x77, sizeof g_bss_blob);
        g_bss_blob[0] = 0;
        g_bss_blob[32770] = 0;
    }

    __attribute__((used, visibility("default")))
    int verify_initial_state(void) {
        if (g_data_val != 0x13572468) return 10;
        if (g_bss_blob[0] != 0xA7 || g_bss_blob[1] != 0x5B) return 11;
        if (g_bss_blob[16] != 0x42) return 12;
        for (size_t i = 100; i < 32700; i++) {
            if (g_bss_blob[i] != 0) return 13;
        }
        if (g_bss_blob[32768] != 0xC3 || g_bss_blob[32769] != 0xD4 || g_bss_blob[32770] != 0xE5) {
            return 14;
        }
        return 0;
    }
    """

    HOST_C = """\
    #include "SegSnap.h"
    #include <dlfcn.h>
    #include <stdio.h>

    typedef void (*mutate_fn)(void);
    typedef int (*verify_fn)(void);

    int main(int argc, char **argv) {
        if (argc != 2) return 1;
        void *h = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
        if (!h) {
            fprintf(stderr, "dlopen: %s\\n", dlerror());
            return 2;
        }
        void *sym = dlsym(h, "dmgame_image_marker");
        Dl_info info;
        if (!sym || !dladdr(sym, &info) || !info.dli_fbase) return 3;
        mutate_fn mutate = (mutate_fn)dlsym(h, "mutate_game_state");
        verify_fn verify = (verify_fn)dlsym(h, "verify_initial_state");
        if (!mutate || !verify) return 4;

        if (verify() != 0) return 5;

        const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
        DmSegSnap seg[2];
        dm_seg_snap_save(mh, "__DATA", &seg[0]);
        dm_seg_snap_save(mh, "__DATA_DIRTY", &seg[1]);
        if (seg[0].bss_sz < 32771 || (seg[0].bss_sz & 7U) == 0) {
            fprintf(stderr, "unexpected __DATA,__bss size %zu\\n", seg[0].bss_sz);
            return 7;
        }

        for (int round = 0; round < 2; round++) {
            mutate();
            if (verify() == 0) return 6;
            dm_seg_snap_restore(&seg[0]);
            dm_seg_snap_restore(&seg[1]);
            int rc = verify();
            if (rc != 0) {
                fprintf(stderr, "verify failed on round %d with code %d\\n", round, rc);
                return rc;
            }
        }

        dm_seg_snap_free(&seg[0]);
        dm_seg_snap_free(&seg[1]);
        return 0;
    }
    """

    def test_raw_page_seam_and_alignment_suite(self):
        root = Path(tempfile.mkdtemp(prefix='test_t_seg_snap_')).resolve()
        self.addCleanup(shutil.rmtree, root)
        exe = root / 't_seg_snap'
        r_cc = subprocess.run(
            ['clang', '-O1', '-g', '-Wall', '-Werror', '-fsanitize=address,undefined',
             f'-I{SHELL_APP_DIR}', str(T_SEG_SNAP_C), '-o', str(exe)],
            capture_output=True, text=True,
        )
        self.assertEqual(r_cc.returncode, 0, r_cc.stderr)
        r_run = subprocess.run([str(exe)], capture_output=True, text=True)
        self.assertEqual(r_run.returncode, 0, r_run.stderr)

    def test_macho_dylib_bss_unaligned_tail_and_pages_restore_cleanly(self):
        root = Path(tempfile.mkdtemp(prefix='test_macho_segsnap_')).resolve()
        self.addCleanup(shutil.rmtree, root)

        dylib_c = root / 'game.c'
        dylib = root / 'libgame.dylib'
        host_c = root / 'host.c'
        host = root / 'host'

        dylib_c.write_text(textwrap.dedent(self.DYLIB_C), encoding='utf-8')
        host_c.write_text(textwrap.dedent(self.HOST_C), encoding='utf-8')

        r_lib = subprocess.run(['clang', '-O1', '-Wall', '-Werror', '-dynamiclib', str(dylib_c), '-o', str(dylib)],
                               capture_output=True, text=True)
        self.assertEqual(r_lib.returncode, 0, r_lib.stderr)

        r_host = subprocess.run(['clang', '-O1', '-Wall', '-Werror', f'-I{SHELL_APP_DIR}', str(host_c), '-o', str(host)],
                                capture_output=True, text=True)
        self.assertEqual(r_host.returncode, 0, r_host.stderr)

        r_run = subprocess.run([str(host), str(dylib)], capture_output=True, text=True)
        self.assertEqual(r_run.returncode, 0, r_run.stderr)

    def test_macho_dylib_tiny_subword_bss_restores_cleanly(self):
        root = Path(tempfile.mkdtemp(prefix='test_macho_segsnap_tiny_')).resolve()
        self.addCleanup(shutil.rmtree, root)

        tiny_c = root / 'tiny.c'
        dylib = root / 'libtiny.dylib'
        host_c = root / 'host_tiny.c'
        host = root / 'host_tiny'

        tiny_c.write_text(
            textwrap.dedent(
                """\
                #include <stdint.h>

                __attribute__((used, visibility("default")))
                const char dmgame_image_marker[] = "DmGame";

                __attribute__((aligned(1), used))
                static uint8_t g_tiny_bss[3];

                __attribute__((used, visibility("default")))
                uint8_t *get_tiny_bss(void) {
                    return g_tiny_bss;
                }

                __attribute__((constructor))
                static void init_tiny(void) {
                    uint8_t *p = g_tiny_bss;
                    __asm__ volatile("" : "+r"(p));
                    p[0] = 0x12;
                    p[1] = 0x34;
                    p[2] = 0x56;
                }

                __attribute__((used, visibility("default")))
                void mutate_game_state(void) {
                    g_tiny_bss[0] = 0xFE;
                    g_tiny_bss[1] = 0xDC;
                    g_tiny_bss[2] = 0xBA;
                }

                __attribute__((used, visibility("default")))
                int verify_initial_state(void) {
                    return (g_tiny_bss[0] == 0x12 && g_tiny_bss[1] == 0x34 && g_tiny_bss[2] == 0x56) ? 0 : 21;
                }
                """
            ),
            encoding='utf-8',
        )
        host_c.write_text(
            textwrap.dedent(self.HOST_C).replace(
                'seg[0].bss_sz < 32771 || (seg[0].bss_sz & 7U) == 0',
                'seg[0].bss_sz == 0 || seg[0].bss_sz >= 8',
            ),
            encoding='utf-8',
        )

        r_lib = subprocess.run(['clang', '-O1', '-Wall', '-Werror', '-dynamiclib', str(tiny_c), '-o', str(dylib)],
                               capture_output=True, text=True)
        self.assertEqual(r_lib.returncode, 0, r_lib.stderr)

        r_host = subprocess.run(['clang', '-O1', '-Wall', '-Werror', f'-I{SHELL_APP_DIR}', str(host_c), '-o', str(host)],
                                capture_output=True, text=True)
        self.assertEqual(r_host.returncode, 0, r_host.stderr)

        r_run = subprocess.run([str(host), str(dylib)], capture_output=True, text=True)
        self.assertEqual(r_run.returncode, 0, r_run.stderr)


if __name__ == '__main__':
    unittest.main()
