#!/usr/bin/env python3
"""Independent pfwd installer; existing rules and live forwarding are preserved.

Supported: Debian/Ubuntu with systemd, Python >= 3.10 and nftables.
Only the manager source is downloaded; never copy a server's private rule set.
"""
from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

SOURCE_URL = 'https://raw.githubusercontent.com/FranklinByte/xray-manager/main/pfwd.py'
SOURCE_SHA256 = 'bddf4875b9916efdd4260ed96604868ed3fc799fe1cb74fb87fd0d283221e044'
WRAPPER = b'#!/usr/bin/env bash\nset -euo pipefail\nexec /usr/local/bin/pfwd "$@"\n'


def load_source(path):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise RuntimeError('pfwd 下载校验失败，未安装；请重新获取最新版安装器。')
    compile(data, str(path), 'exec')
    spec = importlib.util.spec_from_file_location('pfwd_install_candidate', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def has_include(text, nft_path):
    """Accept only the known direct/wildcard includes, not arbitrary comments."""
    paths = re.findall(r'^\s*include\s+"([^"\n]+)"\s*;?\s*(?:#.*)?$', text, re.M)
    return str(nft_path) in paths or str(nft_path.parent/'*.nft') in paths


def checked(*command):
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()


def install(module, source, config, *, sysctl_path=Path('/etc/sysctl.d/99-pfw-forward.conf')):
    """Lock the whole installation; update mode does not apply any nft rules."""
    with module.exclusive_lock(config):
        existing = config.rules_path.exists()
        if existing:
            rules, _ = module.load_rules(config)
            targets = module.load_resolved_targets(config, rules)
            if targets is None:
                raise RuntimeError('发现旧版规则但缺少解析映射，需先单独迁移；不会覆盖或清空现有规则。')
            expected = module.generate_nft(rules, targets)
            if config.nft_path.read_text() != expected:
                raise RuntimeError('持久化 nft 与规则源不一致；先修复一致性，再更新程序。')
            module.verify_runtime(config, rules, targets)
        else:
            # A partial/legacy deployment must never be treated as a blank install.
            if (config.nft_path.exists() or config.resolved_path.exists()
                    or config.program_path.exists() or config.wrapper_path.exists()
                    or module.table_exists(config)):
                raise RuntimeError('发现已有或不完整的 PFW 安装，拒绝初始化空规则；请先检查。')
            rules, targets = [], {}
            expected = module.generate_nft(rules, targets)
            module.validate_runtime_transaction(config, expected)

        tracked = [config.program_path, config.wrapper_path, config.rules_path,
                   config.nft_path, config.resolved_path, config.nftables_conf, sysctl_path]
        before = {p: (p.read_bytes(), p.stat().st_mode & 0o777) if p.exists() else None for p in tracked}
        config.backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        backup = Path(tempfile.mkdtemp(prefix='install-', dir=config.backup_root))
        for path, state in before.items():
            if state is not None:
                dest = backup/str(path).lstrip('/')
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(state[0])
                dest.chmod(state[1])
        enabled_before = subprocess.run(['systemctl', 'is-enabled', 'nftables'],
            text=True, capture_output=True).stdout.strip()
        old_forward = checked('sysctl', '-n', 'net.ipv4.ip_forward')
        applied = False
        try:
            if not existing:
                module.atomic_write(config.rules_path, module.serialize_rules(rules), 0o644)
                module.atomic_write(config.nft_path, expected.encode(), 0o644)
                module.atomic_write(config.resolved_path, module.serialize_resolved_targets(rules, targets), 0o644)
                conf = config.nftables_conf.read_text() if config.nftables_conf.exists() else ''
                if not has_include(conf, config.nft_path):
                    conf = conf.rstrip() + f'\ninclude "{config.nft_path}"\n'
                    module.atomic_write(config.nftables_conf, conf.encode(), 0o644)
                # Check the boot file without applying it (it may contain flush ruleset).
                checked(config.nft_bin, '-c', '-f', str(config.nftables_conf))
                checked('systemctl', 'enable', 'nftables')  # never restart/reload the shared firewall
                module.atomic_write(sysctl_path, b'net.ipv4.ip_forward=1\n', 0o644)
                checked('sysctl', '-w', 'net.ipv4.ip_forward=1')
                module.apply_runtime(config, expected)  # owns only table ip pfwd_nat
                applied = True
                module.verify_runtime(config, rules, targets)
            module.atomic_write(config.program_path, source.read_bytes(), 0o755)
            module.atomic_write(config.wrapper_path, WRAPPER, 0o755)
        except BaseException:
            # Restore files even if a subsequent runtime rollback fails.
            for path, state in before.items():
                if state is None:
                    path.unlink(missing_ok=True)
                else:
                    module.atomic_write(path, state[0], state[1])
            if not existing:
                if applied:
                    checked(config.nft_bin, 'delete', 'table', module.TABLE_FAMILY, module.TABLE_NAME)
                checked('sysctl', '-w', f'net.ipv4.ip_forward={old_forward}')
                if enabled_before == 'disabled':
                    checked('systemctl', 'disable', 'nftables')
            print(f'安装失败，已尝试回滚；备份：{backup}', file=sys.stderr)
            raise
        print(f'pfwd {module.VERSION} 安装完成；备份：{backup}')
        print('已有规则与实时转发保持不变。' if existing else '已初始化空规则，并启用开机加载及 IPv4 转发。')
        print('运行 pfw 打开菜单；pfw status 检查完整状态。')


def main():
    if os.geteuid() != 0:
        raise RuntimeError('请使用 root 运行。')
    if sys.version_info < (3, 10):
        raise RuntimeError('需要 Python 3.10 或更新版本。')
    os_release = Path('/etc/os-release').read_text()
    if not re.search(r'^ID=["\']?(debian|ubuntu)["\']?$', os_release, re.M):
        raise RuntimeError('PFW 安装器当前支持 Debian/Ubuntu；其他系统尚未验收。')
    for command in ('bash', 'nft', 'systemctl', 'sysctl'):
        if not shutil.which(command):
            raise RuntimeError(f'缺少依赖：{command}')
    if not Path('/run/systemd/system').is_dir():
        raise RuntimeError('需要运行中的 systemd。')
    with tempfile.TemporaryDirectory(prefix='pfw-install-') as temp:
        path = Path(temp)/'pfwd.py'
        request = urllib.request.Request(SOURCE_URL, headers={'Cache-Control': 'no-cache'})
        with urllib.request.urlopen(request, timeout=60) as response:
            path.write_bytes(response.read())
        module = load_source(path)
        install(module, path, module.Config.from_env())


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'❌ {exc}', file=sys.stderr)
        sys.exit(1)
