import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pfwd_resolver_test', Path(__file__).resolve().parents[1]/'pfwd.py')
m = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name)/'dns.json'
        patcher = patch.object(m, 'DNS_CONFIG_PATH', self.config)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_default_preserves_system_dns_and_sixty_seconds(self):
        self.assertEqual(m.dns_settings(), ('system', 60))

    def test_explicit_config_and_both_resolution_paths(self):
        self.config.write_text(json.dumps({'server': '1.1.1.1', 'interval_seconds': 30}))
        self.assertEqual(m.dns_settings(), ('1.1.1.1', 30))
        with patch.object(m, 'resolve_explicit_dns', return_value={'192.0.2.1'}) as resolve:
            self.assertEqual(m.resolve_ipv4('test.example'), {'192.0.2.1'})
            self.assertEqual(m.resolve_ipv4_bounded('test.example'), {'192.0.2.1'})
            self.assertEqual(resolve.call_count, 2)
            resolve.assert_called_with('test.example', '1.1.1.1')
            self.assertEqual(m.resolve_ipv4('192.0.2.99'), {'192.0.2.99'})
            self.assertEqual(resolve.call_count, 2)

    def test_cname_and_multiple_a_answers(self):
        output = ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 3\n' \
                 'test.example. 60 IN CNAME other.example.\n' \
                 'other.example. 60 IN A 192.0.2.1\n' \
                 'other.example. 60 IN A 192.0.2.2\n'
        with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')) as run:
            self.assertEqual(m.resolve_explicit_dns('test.example', '1.1.1.1'), {'192.0.2.1', '192.0.2.2'})
            self.assertEqual(run.call_args.args[0][:5], ['dig', '-r', '@1.1.1.1', 'test.example.', 'A'])
            self.assertEqual(run.call_args.kwargs['timeout'], 8)

    def test_nxdomain_servfail_empty_and_invalid_answers_rejected(self):
        for output in ('status: NXDOMAIN', 'status: SERVFAIL', 'status: NOERROR',
                       'status: NOERROR\ntest.example. 60 IN A invalid'):
            with self.subTest(output=output), patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output, '')):
                with self.assertRaises(m.PfwdError):
                    m.resolve_explicit_dns('test.example', '1.1.1.1')

    def test_timeout_no_system_fallback(self):
        self.config.write_text('{"server":"1.1.1.1"}')
        with patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired('dig', 8)), patch.object(m.socket, 'getaddrinfo') as system:
            with self.assertRaisesRegex(m.PfwdError, '不回退系统'):
                m.resolve_ipv4_bounded('test.example')
            system.assert_not_called()

    def test_bad_config_rejected(self):
        for config in ({'server':'1.1.1.1;bad'}, {'interval_seconds':0}, {'interval_seconds':True}, []):
            with self.subTest(config=config):
                self.config.write_text(json.dumps(config))
                with self.assertRaises(m.PfwdError):
                    m.dns_settings()


if __name__ == '__main__':
    unittest.main(verbosity=2)
