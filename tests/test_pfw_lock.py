import dataclasses
import importlib.util
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

program = Path(__file__).resolve().parents[1]/'pfwd.py'
spec = importlib.util.spec_from_file_location('pfwd_tested', program)
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class LockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = Path(self.tmp.name)
        self.c = dataclasses.replace(m.Config.from_env(), rules_path=p/'rules.tsv', nft_path=p/'pfwd.nft',
            resolved_path=p/'resolved.json', lock_path=p/'pfwd.lock', backup_root=p/'backups')
        self.old = [m.Rule(1, 'both', 12345, '192.0.2.1', 443, 'test')]
        self.raw = m.serialize_rules(self.old)
        self.c.rules_path.write_bytes(self.raw)
        self.c.nft_path.write_bytes(b'original nft')
        self.c.resolved_path.write_bytes(m.serialize_resolved_targets(self.old, {'192.0.2.1':'192.0.2.1'}))
        self.env = dict(os.environ, PFWD_RULES=str(self.c.rules_path), PFWD_LOCK=str(self.c.lock_path))

    def available(self):
        return subprocess.run(['flock', '-n', str(self.c.lock_path), 'true']).returncode == 0

    def start(self, *args):
        p = subprocess.Popen([sys.executable, '-u', str(program), *args], env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        def stop():
            if p.poll() is None: p.terminate()
            p.wait(timeout=5)
            p.stdin.close(); p.stdout.close()
        self.addCleanup(stop)
        return p

    def until(self, p, marker):
        result = b''; end = time.monotonic()+5
        while marker.encode() not in result:
            self.assertLess(time.monotonic(), end, result.decode(errors='replace'))
            if select.select([p.stdout], [], [], .1)[0]:
                chunk = os.read(p.stdout.fileno(), 4096)
                self.assertTrue(chunk, result.decode(errors='replace'))
                result += chunk

    def test_two_idle_menus_and_edit_prompt_do_not_lock(self):
        a, b = self.start(), self.start()
        self.until(a, '选择：'); self.until(b, '选择：')
        a.stdin.write(b'2\n'); a.stdin.flush()
        self.until(a, '协议 [')
        self.assertTrue(self.available())
        b.stdin.write(b'1\n0\n'); b.stdin.flush()
        self.assertEqual(b.wait(timeout=5), 0)
        self.assertEqual(self.c.rules_path.read_bytes(), self.raw)

    def test_apply_confirmation_does_not_lock(self):
        p = self.start('apply')
        self.until(p, 'APPLY')
        self.assertTrue(self.available())
        p.stdin.write(b'cancel\n'); p.stdin.flush()
        self.assertEqual(p.wait(timeout=5), 0)

    def test_busy_lock_reports_owner_and_never_enters_transaction(self):
        with m.exclusive_lock(self.c):
            with self.assertRaises(m.PfwdError) as result:
                m.commit_rules(self.c, self.old, self.raw, self.old, 'blocked')
            self.assertIn('pid='+str(os.getpid()), str(result.exception))
            self.assertIn('tty=', str(result.exception))
        self.assertTrue(self.available())

    def test_stale_edit_is_rejected_before_any_writes(self):
        newer = m.serialize_rules([dataclasses.replace(self.old[0], note='other session')])
        self.c.rules_path.write_bytes(newer)
        with patch.object(m, 'atomic_write') as write, patch.object(m, '_create_backup_locked') as backup:
            with self.assertRaisesRegex(m.PfwdError, '其他会话'):
                m.commit_rules(self.c, self.old, self.raw, self.old, 'stale')
            write.assert_not_called(); backup.assert_not_called()
        self.assertEqual(self.c.rules_path.read_bytes(), newer)
        self.assertTrue(self.available())

    def transaction(self, fail):
        newer = [dataclasses.replace(self.old[0], target='192.0.2.2')]
        originals = [p.read_bytes() for p in [self.c.rules_path, self.c.nft_path, self.c.resolved_path]]
        applies = []
        def apply(config, text):
            self.assertFalse(self.available(), 'lock missing during apply/rollback')
            applies.append(text)
            if fail and len(applies)==1: raise RuntimeError('simulated nft failure')
        def snapshot(config, reason):
            self.assertFalse(self.available(), 'lock missing during backup')
            return self.c.backup_root
        with patch.object(m, 'verify_runtime'), patch.object(m, 'validate_runtime_transaction'), \
             patch.object(m, '_create_backup_locked', side_effect=snapshot), \
             patch.object(m, 'update_manifest'), patch.object(m, 'apply_runtime', side_effect=apply):
            if fail:
                with self.assertRaisesRegex(m.PfwdError, '已自动恢复'):
                    m.commit_rules(self.c, self.old, self.raw, newer, 'test')
                self.assertEqual([p.read_bytes() for p in [self.c.rules_path,self.c.nft_path,self.c.resolved_path]], originals)
                self.assertEqual(len(applies), 2)
            else:
                m.commit_rules(self.c, self.old, self.raw, newer, 'test')
                self.assertEqual(self.c.rules_path.read_bytes(), m.serialize_rules(newer))
                self.assertEqual(m.load_resolved_targets(self.c, newer), {'192.0.2.2':'192.0.2.2'})
                self.assertEqual(self.c.nft_path.read_text(), m.generate_nft(newer, {'192.0.2.2':'192.0.2.2'}))
        self.assertTrue(self.available())

    def test_commit_holds_lock_for_all_state_files(self): self.transaction(False)
    def test_rollback_holds_lock_until_original_state_restored(self): self.transaction(True)

    def test_manual_snapshot_uses_same_lock(self):
        def snapshot(config, reason):
            self.assertFalse(self.available())
            return self.c.backup_root
        with patch.object(m, '_create_backup_locked', side_effect=snapshot):
            m.create_backup(self.c, 'manual')
        self.assertTrue(self.available())

if __name__ == '__main__': unittest.main(verbosity=2)
