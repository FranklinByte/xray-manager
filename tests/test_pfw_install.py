"""Run as root in a disposable network namespace:
unshare -n python3 tests/test_pfw_install.py
Uses real nftables; service and sysctl operations are mocked.
"""
import dataclasses
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer', repo/'install-pfw.py')
i = importlib.util.module_from_spec(spec)
spec.loader.exec_module(i)
m = i.load_source(repo/'pfwd.py')
real_run = subprocess.run


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = Path(self.tmp.name)
        self.c = dataclasses.replace(m.Config.from_env(), rules_path=p/'etc/pfwd/rules.tsv',
            nft_path=p/'etc/nftables.d/pfwd.nft', resolved_path=p/'etc/pfwd/resolved.json',
            nftables_conf=p/'etc/nftables.conf', backup_root=p/'backups', lock_path=p/'lock',
            run_dir=p/'run', program_path=p/'bin/pfwd', wrapper_path=p/'bin/pfw')
        self.sysctl = p/'etc/forward.conf'
        self.calls = []
        self.c.nftables_conf.parent.mkdir(parents=True)
        self.c.nftables_conf.write_text('flush ruleset\ntable inet unrelated { }\n')
        real_run(['nft', 'flush', 'ruleset'], check=True)
        real_run(['nft', 'add', 'table', 'inet', 'unrelated'], check=True)
        def fake_run(command, *args, **kwargs):
            if command[0] in ('systemctl', 'sysctl'):
                self.calls.append(tuple(command))
                out = 'disabled\n' if command[0] == 'systemctl' else '0\n'
                return subprocess.CompletedProcess(command, 0, out, '')
            return real_run(command, *args, **kwargs)
        self.patch = patch.object(subprocess, 'run', side_effect=fake_run)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def install(self):
        i.install(m, repo/'pfwd.py', self.c, sysctl_path=self.sysctl)

    def nft(self):
        return real_run(['nft', 'list', 'ruleset'], check=True, capture_output=True).stdout

    def test_fresh_install_keeps_foreign_firewall_and_initializes_state(self):
        self.install()
        self.assertIn(b'table inet unrelated', self.nft())
        self.assertEqual(self.c.program_path.read_bytes(), (repo/'pfwd.py').read_bytes())
        self.assertEqual(self.c.wrapper_path.read_bytes(), i.WRAPPER)
        self.assertEqual(m.load_rules(self.c)[0], [])
        m.verify_runtime(self.c, [], {})
        self.assertIn('flush ruleset\ntable inet unrelated', self.c.nftables_conf.read_text())
        self.assertIn(('systemctl', 'enable', 'nftables'), self.calls)
        self.assertFalse(any('restart' in c or 'reload' in c for c in self.calls))
        # Simulate boot in this isolated namespace using the actual persistent file.
        real_run(['nft', '-f', str(self.c.nftables_conf)], check=True)
        m.verify_runtime(self.c, [], {})
        self.assertIn(b'table inet unrelated', self.nft())

    def test_update_preserves_rules_live_table_and_boot_config(self):
        self.install()
        rules, raw = m.load_rules(self.c)
        m.commit_rules(self.c, rules, raw, [m.Rule(1, 'both', 10083, '192.0.2.1', 10083)], 'test')
        paths = [self.c.rules_path, self.c.resolved_path, self.c.nft_path, self.c.nftables_conf, self.sysctl]
        before = {p: p.read_bytes() for p in paths}
        live = self.nft()
        self.calls.clear()
        with patch.object(m, 'apply_runtime', side_effect=AssertionError('update must not reload')):
            self.install()
        self.assertEqual(before, {p: p.read_bytes() for p in paths})
        self.assertEqual(live, self.nft())
        self.assertFalse(any('enable' in c or '-w' in c for c in self.calls))

    def test_inconsistent_rules_refuse_update(self):
        self.install()
        self.c.nft_path.write_text('bad state')
        live = self.nft()
        with self.assertRaisesRegex(RuntimeError, '不一致'):
            self.install()
        self.assertEqual(live, self.nft())

    def test_partial_install_refuses_empty_initialization(self):
        self.c.nft_path.parent.mkdir(parents=True)
        self.c.nft_path.write_text('legacy rules')
        with self.assertRaisesRegex(RuntimeError, '拒绝初始化'):
            self.install()
        self.assertFalse(self.c.rules_path.exists())

    def test_fresh_failure_rolls_back_files_and_only_own_table(self):
        live, conf = self.nft(), self.c.nftables_conf.read_bytes()
        original = m.atomic_write
        def fail_program(path, *args):
            if path == self.c.program_path:
                raise OSError('simulated disk error')
            return original(path, *args)
        with patch.object(m, 'atomic_write', side_effect=fail_program):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual(self.nft(), live)
        self.assertEqual(self.c.nftables_conf.read_bytes(), conf)
        self.assertFalse(self.c.rules_path.exists())
        self.assertFalse(self.sysctl.exists())

    def test_active_writer_blocks_installer(self):
        with m.exclusive_lock(self.c):
            with self.assertRaises(m.PfwdError):
                self.install()
        self.assertFalse(self.c.program_path.exists())

    def test_wildcard_include_not_duplicated(self):
        conf = f'flush ruleset\ninclude "{self.c.nft_path.parent}/*.nft"\n'
        self.c.nftables_conf.write_text(conf)
        self.install()
        self.assertEqual(self.c.nftables_conf.read_text(), conf)

    def test_bad_download_rejected(self):
        source = Path(self.tmp.name)/'wrong.py'
        source.write_text('print("wrong")')
        with self.assertRaisesRegex(RuntimeError, '校验失败'):
            i.load_source(source)


if __name__ == '__main__':
    if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
        sys.exit('Use unshare -n as root. Never run against the host network namespace.')
    unittest.main(verbosity=2)
