"""Real nftables DNS refresh regression, isolated network namespace only."""
import contextlib
import dataclasses
import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_pfw_install import InstallTests, m, real_run


class DnsTests(unittest.TestCase):
    setUp = InstallTests.setUp
    install = InstallTests.install
    nft = InstallTests.nft

    def seed(self):
        self.install()
        rules = [m.Rule(1, 'both', 16516, 'moving.example', 16516),
                 m.Rule(2, 'both', 10083, 'other.example', 10083),
                 m.Rule(3, 'tcp', 12345, '192.0.2.99', 12345)]
        pins = {'moving.example': '192.0.2.1', 'other.example': '192.0.2.2', '192.0.2.99': '192.0.2.99'}
        with patch.object(m, 'resolve_rule_targets', return_value=pins):
            m.commit_rules(self.c, [], self.c.rules_path.read_bytes(), rules, 'seed')
        return rules, pins

    def snapshot(self):
        return ([p.read_bytes() for p in (self.c.rules_path, self.c.nft_path, self.c.resolved_path)],
                self.nft(), set(self.c.backup_root.iterdir()))

    def answers(self, target):
        return {'moving.example': {'192.0.2.10'}, 'other.example': {'192.0.2.2'}}[target]

    def test_changed_domain_updates_persistent_and_live_both_protocols(self):
        rules, pins = self.seed()
        raw = self.c.rules_path.read_bytes()
        def resolve(target):
            with m.exclusive_lock(self.c):
                pass  # DNS does not monopolize the mutation lock.
            return self.answers(target)
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=resolve):
            m.refresh_dns(self.c)
        pins['moving.example'] = '192.0.2.10'
        self.assertEqual(m.load_resolved_targets(self.c, rules), pins)
        self.assertEqual(self.c.rules_path.read_bytes(), raw)
        m.verify_runtime(self.c, rules, pins)
        self.assertIn(b'table inet unrelated', self.nft())

    def test_same_and_multi_answer_no_writes_or_backups(self):
        self.seed()
        before = self.snapshot()
        with patch.object(m, 'resolve_ipv4_bounded', return_value={'192.0.2.1', '192.0.2.2', '192.0.2.3'}):
            m.refresh_dns(self.c)
        self.assertEqual(before, self.snapshot())

    def test_failed_domain_keeps_pin_while_other_domain_updates(self):
        rules, pins = self.seed()
        def resolve(target):
            if target == 'other.example':
                raise m.PfwdError('simulated DNS outage')
            return {'192.0.2.10'}
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=resolve):
            m.refresh_dns(self.c)
        pins['moving.example'] = '192.0.2.10'
        self.assertEqual(m.load_resolved_targets(self.c, rules), pins)
        m.verify_runtime(self.c, rules, pins)

    def test_all_dns_failures_do_not_write(self):
        self.seed()
        before = self.snapshot()
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=m.PfwdError('DNS outage')):
            m.refresh_dns(self.c)
        self.assertEqual(before, self.snapshot())

    def test_dry_run_does_not_write(self):
        self.seed()
        before = self.snapshot()
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=self.answers):
            m.refresh_dns(self.c, dry_run=True)
        self.assertEqual(before, self.snapshot())

    def test_edit_during_resolution_is_not_overwritten(self):
        rules, pins = self.seed()
        raw = self.c.rules_path.read_bytes()
        new = [dataclasses.replace(r, note='edited during DNS') for r in rules]
        def resolve(target):
            if target == 'moving.example':
                with patch.object(m, 'resolve_rule_targets', return_value=pins):
                    m.commit_rules(self.c, rules, raw, new, 'concurrent user edit')
            return self.answers(target)
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=resolve):
            m.refresh_dns(self.c)
        self.assertEqual(m.load_rules(self.c)[0], new)
        self.assertEqual(m.load_resolved_targets(self.c, new), pins)

    def test_busy_transaction_is_skipped(self):
        self.seed()
        before = self.snapshot()
        with m.exclusive_lock(self.c), patch.object(m, 'resolve_ipv4_bounded') as resolve:
            m.refresh_dns(self.c)
            resolve.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_failed_post_apply_verification_rolls_back(self):
        self.seed()
        files, live, _ = self.snapshot()
        original = m.verify_runtime
        calls = 0
        def verify(*args):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise m.PfwdError('simulated verification failure')
            return original(*args)
        with patch.object(m, 'resolve_ipv4_bounded', side_effect=self.answers), patch.object(m, 'verify_runtime', side_effect=verify):
            with self.assertRaisesRegex(m.PfwdError, '已自动恢复'):
                m.refresh_dns(self.c)
        after = self.snapshot()
        self.assertEqual(files, after[0])
        self.assertEqual(live, after[1])

    def test_inconsistent_persistent_config_stops(self):
        self.seed()
        self.c.nft_path.write_text('bad state')
        before = self.snapshot()
        with self.assertRaisesRegex(m.PfwdError, '不一致'):
            m.refresh_dns(self.c)
        self.assertEqual(before, self.snapshot())

    def test_resolver_is_bounded(self):
        with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('resolver', 8)) as run:
            with self.assertRaisesRegex(m.PfwdError, '保留旧 IP'):
                m.resolve_ipv4_bounded('moving.example')
            self.assertEqual(run.call_args.kwargs['timeout'], 8)


if __name__ == '__main__':
    if os.geteuid() != 0 or os.readlink('/proc/self/ns/net') == os.readlink('/proc/1/ns/net'):
        sys.exit('Use unshare -n as root. Never run against the host network namespace.')
    # Imported fixture class is not part of this suite.
    del InstallTests
    unittest.main(verbosity=2)
