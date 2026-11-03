#!/usr/bin/env python3
"""pfwd - safe nftables port-forward manager."""

from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import dataclasses
import datetime as dt
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Iterator, Mapping, Sequence


VERSION = "2.2.1"
DNS_CONFIG_PATH = Path(os.environ.get("PFWD_DNS_CONFIG", "/etc/pfwd/dns.json"))
TABLE_FAMILY = "ip"
TABLE_NAME = "pfwd_nat"
PROTOCOLS = ("both", "tcp", "udp")
HOST_RE = re.compile(
    r"^(?=.{1,253}\.?$)"
    r"(?:[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.)*"
    r"[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.?$"
)


class PfwdError(RuntimeError):
    pass


class PfwdBusyError(PfwdError):
    pass


@dataclasses.dataclass(frozen=True)
class Config:
    rules_path: Path
    nft_path: Path
    resolved_path: Path
    nftables_conf: Path
    backup_root: Path
    lock_path: Path
    run_dir: Path
    nft_bin: str
    wrapper_path: Path
    program_path: Path

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            rules_path=Path(os.environ.get("PFWD_RULES", "/etc/pfwd/rules.tsv")),
            nft_path=Path(
                os.environ.get("PFWD_NFT", "/etc/nftables.d/pfwd.nft")
            ),
            resolved_path=Path(
                os.environ.get(
                    "PFWD_RESOLVED", "/etc/pfwd/resolved-targets.json"
                )
            ),
            nftables_conf=Path(
                os.environ.get("PFWD_NFTABLES_CONF", "/etc/nftables.conf")
            ),
            backup_root=Path(
                os.environ.get("PFWD_BACKUP_ROOT", "/var/backups/pfwd")
            ),
            lock_path=Path(
                os.environ.get("PFWD_LOCK", "/run/lock/pfwd.lock")
            ),
            run_dir=Path(os.environ.get("PFWD_RUN_DIR", "/run/pfwd")),
            nft_bin=os.environ.get("PFWD_NFT_BIN", "nft"),
            wrapper_path=Path(
                os.environ.get("PFWD_WRAPPER", "/usr/local/bin/pfw")
            ),
            program_path=Path(
                os.environ.get("PFWD_PROGRAM", "/usr/local/bin/pfwd")
            ),
        )


@dataclasses.dataclass(frozen=True)
class Rule:
    rule_id: int
    protocol: str
    listen_port: int
    target: str
    target_port: int
    note: str = ""

    @classmethod
    def from_fields(cls, fields: Sequence[str], line_number: int | None = None) -> "Rule":
        where = f"第 {line_number} 行" if line_number is not None else "规则"
        if len(fields) != 6:
            raise PfwdError(f"{where}必须正好有 6 个 TSV 字段，实际为 {len(fields)} 个")
        try:
            rule_id = int(fields[0])
            listen_port = int(fields[2])
            target_port = int(fields[4])
        except ValueError as exc:
            raise PfwdError(f"{where}的 ID 或端口不是整数") from exc
        rule = cls(
            rule_id=rule_id,
            protocol=fields[1].lower(),
            listen_port=listen_port,
            target=fields[3],
            target_port=target_port,
            note=fields[5],
        )
        validate_rule(rule, where)
        return rule

    def fields(self) -> tuple[str, str, str, str, str, str]:
        return (
            str(self.rule_id),
            self.protocol,
            str(self.listen_port),
            self.target,
            str(self.target_port),
            self.note,
        )


@dataclasses.dataclass(frozen=True)
class IdSelection:
    ids: tuple[int, ...]
    skipped_range_ids: tuple[int, ...] = ()


def validate_target(target: str) -> str:
    if not target or target != target.strip():
        raise PfwdError("目标地址不能为空，也不能带首尾空格")
    if any(ch in target for ch in "\t\r\n\x00"):
        raise PfwdError("目标地址不能包含制表符、换行或 NUL")
    try:
        parsed = ipaddress.ip_address(target)
    except ValueError:
        if not HOST_RE.fullmatch(target):
            raise PfwdError(
                f"目标地址格式无效：{target!r}；只允许 IPv4 或安全的 DNS 主机名"
            )
        return target.rstrip(".")
    if not isinstance(parsed, ipaddress.IPv4Address):
        raise PfwdError("当前 nft 表是 IPv4；目标地址暂不接受 IPv6")
    return str(parsed)


def validate_port(value: int, label: str = "端口") -> int:
    if value < 1 or value > 65535:
        raise PfwdError(f"{label}必须在 1..65535 之间")
    return value


def validate_rule(rule: Rule, where: str = "规则") -> None:
    if rule.rule_id < 1:
        raise PfwdError(f"{where}的 ID 必须为正整数")
    if rule.protocol not in PROTOCOLS:
        raise PfwdError(f"{where}的协议必须是 both、tcp 或 udp")
    validate_port(rule.listen_port, f"{where}监听端口")
    validate_target(rule.target)
    validate_port(rule.target_port, f"{where}目标端口")
    if any(ch in rule.note for ch in "\t\r\n\x00"):
        raise PfwdError(f"{where}的备注不能包含制表符、换行或 NUL")


def protocol_set(protocol: str) -> frozenset[str]:
    return frozenset(("tcp", "udp")) if protocol == "both" else frozenset((protocol,))


def validate_rules(rules: Sequence[Rule]) -> None:
    ids: set[int] = set()
    occupied: dict[tuple[str, int], int] = {}
    for rule in rules:
        validate_rule(rule, f"ID {rule.rule_id}")
        if rule.rule_id in ids:
            raise PfwdError(f"发现重复 ID：{rule.rule_id}")
        ids.add(rule.rule_id)
        for protocol in protocol_set(rule.protocol):
            key = (protocol, rule.listen_port)
            if key in occupied:
                raise PfwdError(
                    f"监听冲突：ID {occupied[key]} 与 ID {rule.rule_id} "
                    f"都使用 {protocol.upper()} {rule.listen_port}"
                )
            occupied[key] = rule.rule_id


def parse_rules_bytes(data: bytes) -> list[Rule]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PfwdError("规则文件不是有效 UTF-8") from exc
    rules: list[Rule] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line:
            raise PfwdError(f"规则文件第 {line_number} 行为空；请删除空行")
        rules.append(Rule.from_fields(line.split("\t"), line_number))
    validate_rules(rules)
    return rules


def serialize_rules(rules: Sequence[Rule]) -> bytes:
    validate_rules(rules)
    if not rules:
        return b""
    text = "\n".join("\t".join(rule.fields()) for rule in rules) + "\n"
    return text.encode("utf-8")


def load_rules(config: Config) -> tuple[list[Rule], bytes]:
    try:
        data = config.rules_path.read_bytes()
    except FileNotFoundError as exc:
        raise PfwdError(f"规则文件不存在：{config.rules_path}") from exc
    return parse_rules_bytes(data), data


def expanded_protocols(rule: Rule) -> tuple[str, ...]:
    if rule.protocol == "both":
        return ("tcp", "udp")
    return (rule.protocol,)


def generate_nft(
    rules: Sequence[Rule],
    resolved_targets: Mapping[str, str] | None = None,
) -> str:
    validate_rules(rules)
    lines = [
        f"table {TABLE_FAMILY} {TABLE_NAME} {{",
        "  chain prerouting { type nat hook prerouting priority dstnat; policy accept;",
    ]
    for rule in rules:
        target = (
            resolved_targets[rule.target]
            if resolved_targets is not None
            else rule.target
        )
        for protocol in expanded_protocols(rule):
            lines.append(
                f"    {protocol} dport {rule.listen_port} counter "
                f"dnat to {target}:{rule.target_port} "
                f'comment "pfwd:{rule.rule_id}:{protocol}"'
            )
    lines.extend(
        [
            "  }",
            "  chain postrouting { type nat hook postrouting priority srcnat; policy accept;",
        ]
    )
    for rule in rules:
        target = (
            resolved_targets[rule.target]
            if resolved_targets is not None
            else rule.target
        )
        for protocol in expanded_protocols(rule):
            lines.append(
                f"    ip daddr {target} {protocol} dport {rule.target_port} "
                f'counter masquerade comment "pfwd:{rule.rule_id}:{protocol}"'
            )
    lines.extend(["  }", "}"])
    return "\n".join(lines) + "\n"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    temp_path = Path(temp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            temp_path.unlink()
        raise


def atomic_remove(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def run_command(
    argv: Sequence[str],
    *,
    input_text: str | None = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(argv),
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise PfwdError(f"找不到命令：{argv[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise PfwdError(f"命令超时：{' '.join(argv)}") from exc


def nft_command(config: Config, *args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return run_command((config.nft_bin, *args), timeout=timeout)


def table_exists(config: Config) -> bool:
    result = nft_command(config, "list", "table", TABLE_FAMILY, TABLE_NAME)
    if result.returncode == 0:
        return True
    lowered = result.stderr.lower()
    if "no such file" in lowered or "not found" in lowered:
        return False
    raise PfwdError(f"无法判断实时 nft 表是否存在：{result.stderr.strip()}")


def build_runtime_transaction(nft_text: str, exists: bool) -> str:
    if exists:
        return f"delete table {TABLE_FAMILY} {TABLE_NAME}\n{nft_text}"
    return nft_text


@contextlib.contextmanager
def temporary_transaction_file(config: Config, content: str) -> Iterator[Path]:
    config.run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(
        prefix="transaction-", suffix=".nft", dir=str(config.run_dir)
    )
    path = Path(name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        yield path
    finally:
        with contextlib.suppress(FileNotFoundError):
            path.unlink()


def validate_runtime_transaction(config: Config, nft_text: str) -> str:
    transaction = build_runtime_transaction(nft_text, table_exists(config))
    with temporary_transaction_file(config, transaction) as path:
        result = nft_command(config, "-c", "-f", str(path))
    if result.returncode != 0:
        raise PfwdError(f"nft 事务校验失败：\n{result.stderr.strip()}")
    return transaction


def apply_runtime(config: Config, nft_text: str) -> None:
    transaction = validate_runtime_transaction(config, nft_text)
    with temporary_transaction_file(config, transaction) as path:
        result = nft_command(config, "-f", str(path))
    if result.returncode != 0:
        raise PfwdError(f"nft 原子应用失败：\n{result.stderr.strip()}")


def dns_settings() -> tuple[str, int]:
    if not DNS_CONFIG_PATH.exists():
        return "system", 60
    try:
        settings = json.loads(DNS_CONFIG_PATH.read_text())
        server = settings.get("server", "system")
        if server != "system":
            server = str(ipaddress.IPv4Address(server))
        interval = settings.get("interval_seconds", 60)
        if type(interval) is not int or not 10 <= interval <= 86400:
            raise ValueError("interval_seconds 必须是 10–86400 的整数")
        return server, interval
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        raise PfwdError(f"DNS 配置无效：{DNS_CONFIG_PATH}：{exc}") from exc


def resolve_explicit_dns(target: str, server: str) -> set[str]:
    """Plain DNS to the configured server only; dig handles CNAME and TCP fallback."""
    try:
        result = subprocess.run(
            ["dig", "-r", "@" + server, validate_target(target).rstrip(".") + ".", "A",
             "+time=2", "+tries=1", "+noall", "+answer", "+comments"],
            capture_output=True, text=True, timeout=8, check=True,
        )
        if not re.search(r"status: NOERROR\b", result.stdout):
            raise ValueError("DNS 返回错误状态")
        addresses = set()
        for line in result.stdout.splitlines():
            if line.startswith(";"):
                continue
            fields = line.split()
            if len(fields) == 5 and fields[2:4] == ["IN", "A"]:
                addresses.add(str(ipaddress.IPv4Address(fields[4])))
        if not addresses:
            raise ValueError("没有 A 记录")
        return addresses
    except (subprocess.SubprocessError, OSError, ValueError) as exc:
        raise PfwdError(f"DNS {server} 解析失败：{target}（{type(exc).__name__}）；不回退系统 DNS") from exc


def resolve_ipv4(target: str) -> set[str]:
    normalized = validate_target(target)
    try:
        return {str(ipaddress.IPv4Address(normalized))}
    except ipaddress.AddressValueError:
        pass
    server, _ = dns_settings()
    if server != "system":
        return resolve_explicit_dns(normalized, server)
    try:
        answers = socket.getaddrinfo(
            normalized, None, family=socket.AF_INET, type=socket.SOCK_STREAM
        )
    except socket.gaierror as exc:
        raise PfwdError(f"DNS 无法解析为 IPv4：{normalized}：{exc}") from exc
    addresses = {entry[4][0] for entry in answers}
    if not addresses:
        raise PfwdError(f"DNS 没有 IPv4 记录：{normalized}")
    return addresses


def resolve_rule_targets(rules: Sequence[Rule]) -> dict[str, str]:
    """Resolve every distinct rule target to one deterministic IPv4 address."""
    resolved: dict[str, str] = {}
    for rule in rules:
        if rule.target in resolved:
            continue
        addresses = resolve_ipv4(rule.target)
        resolved[rule.target] = min(
            addresses, key=lambda address: int(ipaddress.IPv4Address(address))
        )
    return resolved


def serialize_resolved_targets(
    rules: Sequence[Rule], resolved_targets: Mapping[str, str]
) -> bytes:
    required = {rule.target for rule in rules}
    if set(resolved_targets) != required:
        missing = sorted(required - set(resolved_targets))
        extra = sorted(set(resolved_targets) - required)
        raise PfwdError(f"解析映射与规则不匹配；缺少={missing}，多余={extra}")
    normalized: dict[str, str] = {}
    for target in sorted(required):
        try:
            normalized[target] = str(ipaddress.IPv4Address(resolved_targets[target]))
        except ipaddress.AddressValueError as exc:
            raise PfwdError(f"解析映射不是有效 IPv4：{target}") from exc
    payload = {
        "version": 1,
        "rules_sha256": sha256_bytes(serialize_rules(rules)),
        "targets": normalized,
    }
    return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def load_resolved_targets(
    config: Config, rules: Sequence[Rule]
) -> dict[str, str] | None:
    if not config.resolved_path.exists():
        return None
    try:
        payload = json.loads(config.resolved_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PfwdError(f"无法读取解析映射：{config.resolved_path}：{exc}") from exc
    if payload.get("version") != 1 or not isinstance(payload.get("targets"), dict):
        raise PfwdError("解析映射格式或版本无效")
    expected_hash = sha256_bytes(serialize_rules(rules))
    if payload.get("rules_sha256") != expected_hash:
        raise PfwdError("解析映射对应的规则哈希与当前 rules.tsv 不一致")
    required = {rule.target for rule in rules}
    raw_targets = payload["targets"]
    if set(raw_targets) != required:
        missing = sorted(required - set(raw_targets))
        extra = sorted(set(raw_targets) - required)
        raise PfwdError(f"解析映射与规则不匹配；缺少={missing}，多余={extra}")
    resolved: dict[str, str] = {}
    for target in required:
        value = raw_targets[target]
        if not isinstance(value, str):
            raise PfwdError(f"解析映射值不是字符串：{target}")
        try:
            resolved[target] = str(ipaddress.IPv4Address(value))
        except ipaddress.AddressValueError as exc:
            raise PfwdError(f"解析映射不是有效 IPv4：{target} -> {value}") from exc
        try:
            literal = str(ipaddress.IPv4Address(target))
        except ipaddress.AddressValueError:
            continue
        if resolved[target] != literal:
            raise PfwdError(f"IPv4 规则的解析映射被意外改写：{target}")
    return resolved


PRE_RE = re.compile(
    r'^(tcp|udp) dport (\d+).* dnat to ([0-9.]+):(\d+) '
    r'comment "pfwd:(\d+):(tcp|udp)"'
)
POST_RE = re.compile(
    r'^ip daddr ([0-9.]+) (tcp|udp) dport (\d+).* masquerade '
    r'comment "pfwd:(\d+):(tcp|udp)"'
)


def parse_live_table(text: str) -> tuple[dict[tuple[int, str], tuple[int, str, int]], dict[tuple[int, str], tuple[str, int]]]:
    prerouting: dict[tuple[int, str], tuple[int, str, int]] = {}
    postrouting: dict[tuple[int, str], tuple[str, int]] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        pre = PRE_RE.search(line)
        if pre:
            protocol, listen_port, target, target_port, rule_id, comment_protocol = pre.groups()
            if protocol != comment_protocol:
                raise PfwdError(f"实时规则注释协议不一致：{line}")
            prerouting[(int(rule_id), protocol)] = (
                int(listen_port),
                target,
                int(target_port),
            )
            continue
        post = POST_RE.search(line)
        if post:
            target, protocol, target_port, rule_id, comment_protocol = post.groups()
            if protocol != comment_protocol:
                raise PfwdError(f"实时规则注释协议不一致：{line}")
            postrouting[(int(rule_id), protocol)] = (target, int(target_port))
    return prerouting, postrouting


def verify_runtime(
    config: Config,
    rules: Sequence[Rule],
    resolved_targets: Mapping[str, str] | None = None,
) -> None:
    result = nft_command(config, "-n", "list", "table", TABLE_FAMILY, TABLE_NAME)
    if result.returncode != 0:
        raise PfwdError(f"无法读取实时 nft 表：{result.stderr.strip()}")
    prerouting, postrouting = parse_live_table(result.stdout)
    expected_keys: set[tuple[int, str]] = set()
    resolved: dict[str, set[str]] = {}
    mismatches: list[str] = []
    for rule in rules:
        if rule.target not in resolved:
            if resolved_targets is None:
                resolved[rule.target] = resolve_ipv4(rule.target)
            else:
                if rule.target not in resolved_targets:
                    raise PfwdError(f"解析映射缺少目标：{rule.target}")
                resolved[rule.target] = {resolved_targets[rule.target]}
        allowed = resolved[rule.target]
        for protocol in expanded_protocols(rule):
            key = (rule.rule_id, protocol)
            expected_keys.add(key)
            pre = prerouting.get(key)
            post = postrouting.get(key)
            if (
                pre is None
                or pre[0] != rule.listen_port
                or pre[1] not in allowed
                or pre[2] != rule.target_port
            ):
                mismatches.append(f"prerouting ID={rule.rule_id}/{protocol}")
            if (
                post is None
                or post[0] not in allowed
                or post[1] != rule.target_port
            ):
                mismatches.append(f"postrouting ID={rule.rule_id}/{protocol}")
    extras = (set(prerouting) | set(postrouting)) - expected_keys
    missing = expected_keys - (set(prerouting) & set(postrouting))
    if extras:
        mismatches.append(f"额外实时规则：{sorted(extras)}")
    if missing:
        mismatches.append(f"缺少实时规则：{sorted(missing)}")
    if mismatches:
        raise PfwdError("实时 nft 表与规则源不一致：" + "；".join(mismatches))


def update_manifest(backup_dir: Path, **updates: object) -> None:
    path = backup_dir / "manifest.json"
    current: dict[str, object] = {}
    if path.exists():
        with contextlib.suppress(json.JSONDecodeError):
            current = json.loads(path.read_text(encoding="utf-8"))
    current.update(updates)
    atomic_write(
        path,
        (json.dumps(current, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        0o600,
    )


def create_backup(config: Config, reason: str) -> Path:
    with exclusive_lock(config):
        return _create_backup_locked(config, reason)


def _create_backup_locked(config: Config, reason: str) -> Path:
    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%S.%fZ")
    config.backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup_dir = config.backup_root / f"{stamp}-{os.getpid()}"
    backup_dir.mkdir(mode=0o700)
    copied: dict[str, dict[str, object]] = {}
    sources = {
        "rules.tsv": config.rules_path,
        "pfwd.nft": config.nft_path,
        "resolved-targets.json": config.resolved_path,
        "nftables.conf": config.nftables_conf,
        "pfw": config.wrapper_path,
        "pfwd": config.program_path,
    }
    for name, source in sources.items():
        if not source.exists():
            continue
        destination = backup_dir / name
        shutil.copy2(source, destination)
        data = destination.read_bytes()
        copied[name] = {
            "source": str(source),
            "size": len(data),
            "sha256": sha256_bytes(data),
        }
    live = nft_command(config, "-a", "list", "table", TABLE_FAMILY, TABLE_NAME)
    atomic_write(
        backup_dir / "live-table.nft",
        (live.stdout if live.returncode == 0 else live.stderr).encode("utf-8"),
        0o600,
    )
    ruleset = nft_command(config, "-j", "list", "ruleset")
    atomic_write(
        backup_dir / "live-ruleset.json",
        (ruleset.stdout if ruleset.returncode == 0 else ruleset.stderr).encode("utf-8"),
        0o600,
    )
    update_manifest(
        backup_dir,
        created_at=now.isoformat(),
        pfwd_version=VERSION,
        reason=reason,
        status="snapshot",
        files=copied,
        live_table_rc=live.returncode,
        live_ruleset_rc=ruleset.returncode,
    )
    return backup_dir


def require_root() -> None:
    if os.geteuid() != 0:
        raise PfwdError("修改或应用规则必须以 root 运行")


@contextlib.contextmanager
def exclusive_lock(config: Config) -> Iterator[None]:
    config.lock_path.parent.mkdir(parents=True, exist_ok=True)
    with config.lock_path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            handle.seek(0)
            owner = handle.read(512).strip() or "持锁信息暂不可用"
            raise PfwdBusyError(
                f"另一个 pfw 正在提交或创建快照（{owner}）；请稍后重试。"
                "若为旧版闲置菜单，请在对应终端退出菜单；不要删除锁文件。"
            ) from exc
        handle.seek(0)
        handle.truncate()
        tty = os.ttyname(0) if os.isatty(0) else "无交互终端"
        handle.write(f"pid={os.getpid()} tty={tty} version={VERSION}\n")
        handle.flush()
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def restore_files(
    config: Config,
    old_rules_bytes: bytes,
    old_nft_bytes: bytes,
    old_resolved_bytes: bytes | None,
    old_rules: Sequence[Rule],
    old_runtime_nft: str,
    old_runtime_targets: Mapping[str, str],
) -> None:
    atomic_write(config.rules_path, old_rules_bytes, 0o644)
    atomic_write(config.nft_path, old_nft_bytes, 0o644)
    if old_resolved_bytes is None:
        atomic_remove(config.resolved_path)
    else:
        atomic_write(config.resolved_path, old_resolved_bytes, 0o644)
    apply_runtime(config, old_runtime_nft)
    verify_runtime(config, old_rules, old_runtime_targets)


def commit_rules(
    config: Config,
    old_rules: Sequence[Rule],
    old_rules_bytes: bytes,
    new_rules: Sequence[Rule],
    reason: str,
    *,
    require_live_sync: bool = True,
    force_apply: bool = False,
) -> Path:
    require_root()
    # 所有交互输入和 APPLY 确认均在调用前完成；锁覆盖检查、写入及回滚。
    with exclusive_lock(config):
        return _commit_rules_locked(
            config, old_rules, old_rules_bytes, new_rules, reason,
            require_live_sync=require_live_sync, force_apply=force_apply,
        )


def _commit_rules_locked(
    config: Config,
    old_rules: Sequence[Rule],
    old_rules_bytes: bytes,
    new_rules: Sequence[Rule],
    reason: str,
    *,
    require_live_sync: bool = True,
    force_apply: bool = False,
    resolved_targets: Mapping[str, str] | None = None,
) -> Path:
    require_root()
    validate_rules(new_rules)
    current_bytes = config.rules_path.read_bytes()
    if current_bytes != old_rules_bytes:
        raise PfwdError("其他会话已修改规则；本次未提交，请重新打开该操作并确认最新规则")
    old_pinned_targets = load_resolved_targets(config, old_rules)
    if require_live_sync:
        verify_runtime(config, old_rules, old_pinned_targets)
    new_rules_bytes = serialize_rules(new_rules)
    if new_rules_bytes == old_rules_bytes and not force_apply:
        raise PfwdError("没有任何实际变化")
    old_runtime_targets = old_pinned_targets or resolve_rule_targets(old_rules)
    old_runtime_nft = generate_nft(old_rules, old_runtime_targets)
    new_resolved_targets = (
        resolve_rule_targets(new_rules) if resolved_targets is None else dict(resolved_targets)
    )
    if set(new_resolved_targets) != {r.target for r in new_rules}:
        raise PfwdError("提交解析映射与目标集合不匹配")
    for target, value in new_resolved_targets.items():
        try:
            ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError as exc:
            raise PfwdError(f"提交解析映射不是 IPv4：{target}") from exc
        try:
            literal = str(ipaddress.IPv4Address(target))
        except ipaddress.AddressValueError:
            continue
        if literal != value:
            raise PfwdError(f"不允许改写固定 IPv4 目标：{target}")
    new_resolved_bytes = serialize_resolved_targets(new_rules, new_resolved_targets)
    new_nft_bytes = generate_nft(new_rules, new_resolved_targets).encode("utf-8")
    validate_runtime_transaction(config, new_nft_bytes.decode("utf-8"))
    backup_dir = _create_backup_locked(config, reason)
    old_nft_bytes = config.nft_path.read_bytes() if config.nft_path.exists() else b""
    old_resolved_bytes = (
        config.resolved_path.read_bytes() if config.resolved_path.exists() else None
    )
    try:
        atomic_write(config.rules_path, new_rules_bytes, 0o644)
        atomic_write(config.nft_path, new_nft_bytes, 0o644)
        atomic_write(config.resolved_path, new_resolved_bytes, 0o644)
        apply_runtime(config, new_nft_bytes.decode("utf-8"))
        verify_runtime(config, new_rules, new_resolved_targets)
        if config.rules_path.read_bytes() != new_rules_bytes:
            raise PfwdError("应用后规则文件校验失败")
        if config.nft_path.read_bytes() != new_nft_bytes:
            raise PfwdError("应用后持久化 nft 文件校验失败")
        if config.resolved_path.read_bytes() != new_resolved_bytes:
            raise PfwdError("应用后解析映射文件校验失败")
    except BaseException as exc:
        rollback_error: BaseException | None = None
        try:
            restore_files(
                config,
                old_rules_bytes,
                old_nft_bytes,
                old_resolved_bytes,
                old_rules,
                old_runtime_nft,
                old_runtime_targets,
            )
        except BaseException as rollback_exc:
            rollback_error = rollback_exc
        update_manifest(
            backup_dir,
            status="rollback_failed" if rollback_error else "rolled_back",
            error=str(exc),
            rollback_error=str(rollback_error) if rollback_error else None,
        )
        if rollback_error:
            raise PfwdError(
                f"应用失败且自动回滚也失败。备份：{backup_dir}\n"
                f"应用错误：{exc}\n回滚错误：{rollback_error}"
            ) from exc
        raise PfwdError(f"应用失败，已自动恢复原状态。备份：{backup_dir}\n{exc}") from exc
    update_manifest(
        backup_dir,
        status="committed",
        committed_at=dt.datetime.now(dt.timezone.utc).isoformat(),
        new_rules_sha256=sha256_bytes(new_rules_bytes),
        new_nft_sha256=sha256_bytes(new_nft_bytes),
        new_resolved_sha256=sha256_bytes(new_resolved_bytes),
    )
    return backup_dir


def rule_endpoint(rule: Rule) -> str:
    return f"{rule.target}:{rule.target_port}"


def print_rules(rules: Sequence[Rule]) -> None:
    if not rules:
        print("(无规则)")
        return
    print(f"{'ID':>4}  {'协议':<5} {'监听端口':>7}  {'目标地址':<28} {'目标端口':>7}  备注")
    print("-" * 94)
    for rule in rules:
        print(
            f"{rule.rule_id:>4}  {rule.protocol:<5} {rule.listen_port:>7}  "
            f"{rule.target:<28} {rule.target_port:>7}  {rule.note or '-'}"
        )


def print_diff(
    old_rules: Sequence[Rule],
    new_rules: Sequence[Rule],
    *,
    include_unchanged: bool = False,
) -> int:
    old_by_id = {rule.rule_id: rule for rule in old_rules}
    new_by_id = {rule.rule_id: rule for rule in new_rules}
    changed = 0
    print("\n变更预览：")
    for rule_id in sorted(set(old_by_id) | set(new_by_id)):
        old = old_by_id.get(rule_id)
        new = new_by_id.get(rule_id)
        if old == new and not include_unchanged:
            continue
        changed += old != new
        if old is None and new is not None:
            print(
                f"  + ID {new.rule_id}: {new.protocol} {new.listen_port} -> "
                f"{rule_endpoint(new)}  [{new.note or '-'}]"
            )
        elif new is None and old is not None:
            print(
                f"  - ID {old.rule_id}: {old.protocol} {old.listen_port} -> "
                f"{rule_endpoint(old)}  [{old.note or '-'}]"
            )
        elif old is not None and new is not None:
            print(
                f"  ~ ID {rule_id}: {old.protocol}/{old.listen_port} "
                f"{rule_endpoint(old)} -> "
                f"{new.protocol}/{new.listen_port} {rule_endpoint(new)}"
            )
    print(f"共 {changed} 条规则发生变化。")
    return changed


def confirm_apply() -> bool:
    answer = input("输入 APPLY 确认“备份 + 原子应用”，其它输入取消：").strip()
    return answer == "APPLY"


def parse_id_selector(expression: str, available_ids: Iterable[int]) -> IdSelection:
    available = set(available_ids)
    selected: set[int] = set()
    skipped_range_ids: set[int] = set()
    missing_explicit_ids: set[int] = set()
    tokens = [token for token in re.split(r"[\s,，]+", expression.strip()) if token]
    if not tokens:
        raise PfwdError("没有输入任何 ID")
    for token in tokens:
        if re.fullmatch(r"\d+", token):
            rule_id = int(token)
            if rule_id in available:
                selected.add(rule_id)
            else:
                missing_explicit_ids.add(rule_id)
            continue
        match = re.fullmatch(r"(\d+)-(\d+)", token)
        if not match:
            raise PfwdError(f"无法识别的 ID 表达式：{token}")
        start, end = map(int, match.groups())
        if start > end:
            raise PfwdError(f"ID 区间起点大于终点：{token}")
        if end - start > 100_000:
            raise PfwdError(f"ID 区间过大：{token}")
        range_ids = set(range(start, end + 1))
        existing = range_ids & available
        if not existing:
            raise PfwdError(f"ID 区间内没有任何现有规则：{token}")
        selected.update(existing)
        skipped_range_ids.update(range_ids - available)
    if missing_explicit_ids:
        raise PfwdError(f"单独指定的 ID 不存在：{sorted(missing_explicit_ids)}")
    return IdSelection(
        ids=tuple(sorted(selected)),
        skipped_range_ids=tuple(sorted(skipped_range_ids)),
    )


def selected_ids_with_notice(
    expression: str, available_ids: Iterable[int]
) -> list[int]:
    selection = parse_id_selector(expression, available_ids)
    if selection.skipped_range_ids:
        skipped = ", ".join(map(str, selection.skipped_range_ids))
        print(f"⚠️ 区间内不存在的 ID 已自动跳过：{skipped}")
    return list(selection.ids)


def parse_mapping_line(line: str) -> tuple[int, str, int | None]:
    parts = line.split()
    if len(parts) == 2 and ":" in parts[1]:
        endpoint, port_text = parts[1].rsplit(":", 1)
        parts = [parts[0], endpoint, port_text]
    if len(parts) != 3:
        raise PfwdError("映射格式应为：ID 新地址 新端口，或 ID 新地址:新端口")
    try:
        rule_id = int(parts[0])
    except ValueError as exc:
        raise PfwdError(f"ID 不是整数：{parts[0]}") from exc
    target = parts[1]
    if target != "-":
        target = validate_target(target)
    if parts[2] == "-":
        target_port = None
    else:
        try:
            target_port = int(parts[2])
        except ValueError as exc:
            raise PfwdError(f"目标端口不是整数：{parts[2]}") from exc
        validate_port(target_port, "目标端口")
    return rule_id, target, target_port


def apply_mappings(
    rules: Sequence[Rule],
    mappings: Sequence[tuple[int, str, int | None]],
) -> list[Rule]:
    by_id = {rule.rule_id: rule for rule in rules}
    seen: set[int] = set()
    for rule_id, target, target_port in mappings:
        if rule_id not in by_id:
            raise PfwdError(f"ID 不存在：{rule_id}")
        if rule_id in seen:
            raise PfwdError(f"映射中重复出现 ID：{rule_id}")
        seen.add(rule_id)
        old = by_id[rule_id]
        by_id[rule_id] = dataclasses.replace(
            old,
            target=old.target if target == "-" else validate_target(target),
            target_port=old.target_port if target_port is None else target_port,
        )
    result = [by_id[rule.rule_id] for rule in rules]
    validate_rules(result)
    return result


def select_rules_interactive(rules: Sequence[Rule]) -> list[int]:
    print("\n选择规则：")
    print("  1) 按当前目标地址精确选择")
    print("  2) 按 ID/区间选择，例如 10,12-14,18")
    print("  3) 选择全部规则")
    mode = input("选择 [1-3]：").strip()
    if mode == "1":
        counts: dict[str, int] = {}
        for rule in rules:
            counts[rule.target] = counts.get(rule.target, 0) + 1
        print("当前目标地址：")
        for target, count in sorted(counts.items()):
            print(f"  {target:<32} {count} 条")
        target = input("输入要精确匹配的当前目标地址：").strip()
        selected = [rule.rule_id for rule in rules if rule.target == target]
        if not selected:
            raise PfwdError(f"没有规则精确匹配：{target}")
        return selected
    if mode == "2":
        return selected_ids_with_notice(
            input("输入 ID/区间："), (rule.rule_id for rule in rules)
        )
    if mode == "3":
        return [rule.rule_id for rule in rules]
    raise PfwdError("无效选择")


def uniform_batch_interactive(rules: Sequence[Rule]) -> list[Rule]:
    selected = set(select_rules_interactive(rules))
    print(f"已选择 {len(selected)} 条：{', '.join(map(str, sorted(selected)))}")
    target_text = input("新目标地址（输入 - 表示保持原地址）：").strip()
    if target_text != "-":
        target_text = validate_target(target_text)
    print("目标端口策略：")
    print("  1) 保持每条规则原目标端口")
    print("  2) 所有选中规则使用同一个新端口")
    print("  3) 每条规则的目标端口等于其监听端口")
    port_mode = input("选择 [1-3]：").strip()
    fixed_port: int | None = None
    if port_mode == "2":
        try:
            fixed_port = int(input("统一的新目标端口：").strip())
        except ValueError as exc:
            raise PfwdError("目标端口不是整数") from exc
        validate_port(fixed_port, "目标端口")
    elif port_mode not in {"1", "3"}:
        raise PfwdError("无效端口策略")
    result: list[Rule] = []
    for rule in rules:
        if rule.rule_id not in selected:
            result.append(rule)
            continue
        if port_mode == "1":
            target_port = rule.target_port
        elif port_mode == "2":
            assert fixed_port is not None
            target_port = fixed_port
        else:
            target_port = rule.listen_port
        result.append(
            dataclasses.replace(
                rule,
                target=rule.target if target_text == "-" else target_text,
                target_port=target_port,
            )
        )
    validate_rules(result)
    return result


def pasted_batch_interactive(rules: Sequence[Rule]) -> list[Rule]:
    print("\n逐行粘贴映射；空行结束：")
    print("  ID 新地址 新端口")
    print("  ID 新地址:新端口")
    print("地址或端口使用 - 可保持原值。")
    mappings: list[tuple[int, str, int | None]] = []
    while True:
        line = input("> ").strip()
        if not line:
            break
        mappings.append(parse_mapping_line(line))
    if not mappings:
        raise PfwdError("没有输入映射")
    return apply_mappings(rules, mappings)


def batch_interactive(config: Config) -> None:
    rules, source_bytes = load_rules(config)
    print_rules(rules)
    print("\n批量修改方式：")
    print("  1) 选中多条后统一修改（地址 + 灵活端口策略）")
    print("  2) 粘贴逐条映射（每条可以使用不同地址和端口）")
    mode = input("选择 [1-2]：").strip()
    if mode == "1":
        new_rules = uniform_batch_interactive(rules)
    elif mode == "2":
        new_rules = pasted_batch_interactive(rules)
    else:
        raise PfwdError("无效选择")
    changed = print_diff(rules, new_rules)
    if changed == 0:
        raise PfwdError("输入结果与当前规则相同，没有变化")
    if not confirm_apply():
        print("已取消，未写入任何规则。")
        return
    backup = commit_rules(
        config,
        rules,
        source_bytes,
        new_rules,
        f"batch edit: {changed} rules",
    )
    print(f"✅ 已安全应用 {changed} 条批量修改")
    print(f"备份：{backup}")


def add_interactive(config: Config) -> None:
    rules, source_bytes = load_rules(config)
    next_id = max((rule.rule_id for rule in rules), default=0) + 1
    print(f"新规则 ID：{next_id}")
    protocol = input("协议 [both/tcp/udp，默认 both]：").strip().lower() or "both"
    try:
        listen_port = int(input("本机监听端口：").strip())
        target = validate_target(input("目标 IPv4/域名：").strip())
        target_port = int(input("目标端口：").strip())
    except ValueError as exc:
        raise PfwdError("端口不是整数") from exc
    note = input("备注（可空）：")
    new_rule = Rule(next_id, protocol, listen_port, target, target_port, note)
    validate_rule(new_rule)
    new_rules = [*rules, new_rule]
    validate_rules(new_rules)
    print_diff(rules, new_rules)
    if not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(config, rules, source_bytes, new_rules, f"add ID {next_id}")
    print(f"✅ 已添加并应用 ID {next_id}\n备份：{backup}")


def edit_interactive(config: Config) -> None:
    rules, source_bytes = load_rules(config)
    print_rules(rules)
    try:
        rule_id = int(input("要修改的 ID：").strip())
    except ValueError as exc:
        raise PfwdError("ID 不是整数") from exc
    by_id = {rule.rule_id: rule for rule in rules}
    if rule_id not in by_id:
        raise PfwdError(f"ID 不存在：{rule_id}")
    old = by_id[rule_id]
    protocol = input(f"协议 [{old.protocol}]：").strip().lower() or old.protocol
    listen_text = input(f"监听端口 [{old.listen_port}]：").strip()
    target_text = input(f"目标地址 [{old.target}]：").strip()
    target_port_text = input(f"目标端口 [{old.target_port}]：").strip()
    note_text = input(f"备注 [{old.note or '-'}]（输入 - 清空）：")
    try:
        listen_port = int(listen_text) if listen_text else old.listen_port
        target_port = int(target_port_text) if target_port_text else old.target_port
    except ValueError as exc:
        raise PfwdError("端口不是整数") from exc
    new = dataclasses.replace(
        old,
        protocol=protocol,
        listen_port=listen_port,
        target=validate_target(target_text) if target_text else old.target,
        target_port=target_port,
        note="" if note_text == "-" else (note_text if note_text else old.note),
    )
    new_rules = [new if rule.rule_id == rule_id else rule for rule in rules]
    validate_rules(new_rules)
    print_diff(rules, new_rules)
    if not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(config, rules, source_bytes, new_rules, f"edit ID {rule_id}")
    print(f"✅ 已修改并应用 ID {rule_id}\n备份：{backup}")


def delete_interactive(config: Config) -> None:
    rules, source_bytes = load_rules(config)
    print_rules(rules)
    selected = set(
        selected_ids_with_notice(
            input("输入要删除的 ID/区间："), (rule.rule_id for rule in rules)
        )
    )
    new_rules = [rule for rule in rules if rule.rule_id not in selected]
    print_diff(rules, new_rules)
    if not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(
        config,
        rules,
        source_bytes,
        new_rules,
        f"delete IDs {','.join(map(str, sorted(selected)))}",
    )
    print(f"✅ 已删除并应用 {len(selected)} 条规则\n备份：{backup}")


def status_report(config: Config) -> bool:
    ok = True
    print(f"pfwd {VERSION} 状态检查")
    try:
        rules, rules_bytes = load_rules(config)
        print(f"✅ 规则源：{len(rules)} 条，SHA256 {sha256_bytes(rules_bytes)}")
    except PfwdError as exc:
        print(f"❌ 规则源：{exc}")
        return False
    resolved_targets: dict[str, str] | None = None
    try:
        resolved_targets = load_resolved_targets(config, rules)
        if resolved_targets is None:
            print("⚠️ 当前仍是依赖开机 DNS 的旧持久化格式；请执行 pfw apply 迁移")
        else:
            print("✅ 启动规则全部使用固定 IPv4，开机加载不依赖 DNS")
    except PfwdError as exc:
        ok = False
        print(f"❌ 解析映射：{exc}")
    generated = generate_nft(rules, resolved_targets).encode("utf-8")
    try:
        stored = config.nft_path.read_bytes()
        if stored == generated:
            print("✅ 持久化 nft 文件与规则源一致")
        else:
            ok = False
            print("❌ 持久化 nft 文件与规则源不一致")
    except FileNotFoundError:
        ok = False
        print(f"❌ 持久化 nft 文件不存在：{config.nft_path}")
    try:
        validate_runtime_transaction(config, generated.decode("utf-8"))
        print("✅ nft 原子事务预检通过")
    except PfwdError as exc:
        ok = False
        print(f"❌ nft 原子事务预检失败：{exc}")
    try:
        verify_runtime(config, rules, resolved_targets)
        print("✅ 实时 nft 表与规则源一致")
    except PfwdError as exc:
        ok = False
        print(f"❌ 实时 nft 表：{exc}")
    if resolved_targets is not None:
        for target, pinned in sorted(resolved_targets.items()):
            try:
                ipaddress.IPv4Address(target)
                continue
            except ipaddress.AddressValueError:
                pass
            try:
                current = resolve_ipv4(target)
            except PfwdError as exc:
                print(f"⚠️ 当前 DNS 无法刷新 {target}，已固定使用 {pinned}：{exc}")
                continue
            if pinned not in current:
                print(
                    f"⚠️ 域名 {target} 当前解析为 {', '.join(sorted(current))}，"
                    f"持久化仍为 {pinned}；运行 pfw apply 可更新"
                )
    enabled = run_command(("systemctl", "is-enabled", "nftables"))
    active = run_command(("systemctl", "is-active", "nftables"))
    print(
        f"ℹ️ nftables.service："
        f"{enabled.stdout.strip() or 'unknown'} / {active.stdout.strip() or 'unknown'}"
    )
    backups = list_backup_dirs(config)
    print(f"ℹ️ 可用备份：{len(backups)} 个，目录 {config.backup_root}")
    return ok


def resolve_ipv4_bounded(target: str) -> set[str]:
    """Bound libc resolver time in a child, outside the mutation lock."""
    server, _ = dns_settings()
    if server != "system":
        return resolve_explicit_dns(target, server)
    code = (
        "import json,socket,sys; "
        "print(json.dumps(sorted({x[4][0] for x in socket.getaddrinfo("
        "sys.argv[1],None,family=socket.AF_INET,type=socket.SOCK_STREAM)})))"
    )
    try:
        result = subprocess.run(
            [sys.executable, "-c", code, validate_target(target)],
            capture_output=True, text=True, timeout=8, check=True,
        )
        values = json.loads(result.stdout)
        addresses = {str(ipaddress.IPv4Address(value)) for value in values}
        if not addresses:
            raise ValueError("没有 A 记录")
        return addresses
    except (subprocess.SubprocessError, OSError, ValueError, TypeError) as exc:
        raise PfwdError(f"DNS 刷新失败：{target}（{type(exc).__name__}），保留旧 IP") from exc


def refresh_dns(config: Config, *, dry_run: bool = False) -> None:
    require_root()
    # A coherent short snapshot first; never hold the lock during DNS requests.
    try:
        with exclusive_lock(config):
            rules, source_bytes = load_rules(config)
            pins = load_resolved_targets(config, rules)
            if pins is None:
                raise PfwdError("缺少解析映射，请先使用 pfw apply 迁移旧格式")
            mapping_bytes = config.resolved_path.read_bytes()
            nft_bytes = config.nft_path.read_bytes()
            if nft_bytes != generate_nft(rules, pins).encode():
                raise PfwdError("持久化文件不一致，自动刷新已停止；请先修复规则状态")
    except PfwdBusyError:
        print("DNS 刷新跳过：另一个写入事务正在执行，下次重试。")
        return
    domains = []
    for target in pins:
        try:
            ipaddress.IPv4Address(target)
        except ipaddress.AddressValueError:
            domains.append(target)
    updated = dict(pins)
    changes = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        jobs = {target: pool.submit(resolve_ipv4_bounded, target) for target in sorted(domains)}
        for target, job in jobs.items():
            try:
                answers = job.result()
            except PfwdError as exc:
                print(f"⚠️ {exc}", file=sys.stderr)
                continue
            if pins[target] in answers:
                continue  # Keep the current answer across round-robin ordering changes.
            updated[target] = min(answers, key=lambda ip: int(ipaddress.IPv4Address(ip)))
            ids = ",".join(str(r.rule_id) for r in rules if r.target == target)
            changes.append(f"{target}: {pins[target]} -> {updated[target]}（ID {ids}）")
    if not changes:
        print(f"DNS 刷新：检查 {len(domains)} 个域名，无需变更。")
        return
    print("\n".join(changes))
    if dry_run:
        print("仅预览，未修改配置或实时规则。")
        return
    try:
        with exclusive_lock(config):
            # An edit or another refresher may have committed during DNS lookup.
            if (config.rules_path.read_bytes() != source_bytes
                    or config.resolved_path.read_bytes() != mapping_bytes
                    or config.nft_path.read_bytes() != nft_bytes):
                print("DNS 刷新跳过：解析期间配置已变化，下次读取新配置重试。")
                return
            backup = _commit_rules_locked(
                config, rules, source_bytes, rules, "automatic DNS refresh: " + "; ".join(changes),
                force_apply=True, resolved_targets=updated,
            )
            print(f"✅ DNS 刷新已提交；备份：{backup}")
    except PfwdBusyError:
        print("DNS 刷新跳过：另一个写入事务正在执行，下次重试。")


DNS_SERVICE = """# Managed by pfwd dns-auto
[Unit]
Description=Refresh PFW domain targets safely
Wants=network-online.target
After=network-online.target nftables.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pfwd refresh-dns
# DNS subprocesses are bounded; do not kill a firewall transaction mid-rollback.
TimeoutStartSec=0
UMask=0077
Nice=10
NoNewPrivileges=true
PrivateTmp=true
"""

DNS_TIMER = """# Managed by pfwd dns-auto
[Unit]
Description=Check PFW domain targets every minute

[Timer]
OnBootSec=30s
OnUnitInactiveSec=60s
AccuracySec=1s
Unit=pfwd-dns-refresh.service

[Install]
WantedBy=timers.target
"""


def dns_auto(action: str) -> None:
    require_root()
    def systemctl(*args: str) -> None:
        result = run_command(("systemctl", *args))
        if result.stdout.strip():
            print(result.stdout.strip())
        if result.returncode:
            raise PfwdError(result.stderr.strip() or f"systemctl {' '.join(args)} 失败")
    if action == "status":
        systemctl("list-timers", "--all", "--no-pager", "pfwd-dns-refresh.timer")
        return
    if action == "disable":
        systemctl("disable", "--now", "pfwd-dns-refresh.timer")
        print("已关闭自动 DNS 刷新；已在执行的事务会安全完成。")
        return
    if not Path("/run/systemd/system").is_dir():
        raise PfwdError("自动刷新定时器需要 systemd")
    server, interval = dns_settings()
    if server != "system" and not shutil.which("dig"):
        raise PfwdError("指定 DNS 服务器需要 dig，请安装 dnsutils")
    paths = {
        Path("/etc/systemd/system/pfwd-dns-refresh.service"): DNS_SERVICE,
        Path("/etc/systemd/system/pfwd-dns-refresh.timer"): DNS_TIMER.replace(
            "every minute", f"every {interval} seconds"
        ).replace("OnUnitInactiveSec=60s", f"OnUnitInactiveSec={interval}s"),
    }
    for path in paths:
        if path.exists() and not path.read_text().startswith("# Managed by pfwd dns-auto\n"):
            raise PfwdError(f"已有非本工具创建的配置，拒绝覆盖：{path}")
    for path, content in paths.items():
        atomic_write(path, content.encode(), 0o644)
    systemctl("daemon-reload")
    systemctl("enable", "--now", "pfwd-dns-refresh.timer")
    systemctl("restart", "pfwd-dns-refresh.timer")
    print(f"已启用自动 DNS 刷新：DNS={server}，每次检查结束后 {interval} 秒再次运行，开机自动启用。")


def safe_apply_current(config: Config) -> None:
    rules, source_bytes = load_rules(config)
    print_rules(rules)
    print("将重新生成持久化配置，并用单个 nft 原子事务应用当前规则。")
    if not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(
        config,
        rules,
        source_bytes,
        rules,
        "safe reapply current rules",
        require_live_sync=False,
        force_apply=True,
    )
    print(f"✅ 当前规则已安全重新应用\n备份：{backup}")


def list_backup_dirs(config: Config) -> list[Path]:
    if not config.backup_root.exists():
        return []
    return sorted(
        (
            path
            for path in config.backup_root.iterdir()
            if path.is_dir() and (path / "rules.tsv").exists()
        ),
        reverse=True,
    )


def backup_restore_interactive(config: Config) -> None:
    print("  1) 立即创建完整快照")
    print("  2) 从历史快照恢复规则")
    mode = input("选择 [1-2]：").strip()
    if mode == "1":
        backup = create_backup(config, "manual snapshot")
        print(f"✅ 快照已创建：{backup}")
        return
    if mode != "2":
        raise PfwdError("无效选择")
    restore_interactive(config)


def restore_interactive(config: Config) -> None:
    backups = list_backup_dirs(config)
    if not backups:
        raise PfwdError("没有可恢复的备份")
    for index, path in enumerate(backups, 1):
        manifest_path = path / "manifest.json"
        status = "unknown"
        reason = ""
        if manifest_path.exists():
            with contextlib.suppress(Exception):
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                status = str(manifest.get("status", "unknown"))
                reason = str(manifest.get("reason", ""))
        print(f"  {index}) {path.name}  [{status}] {reason}")
    try:
        index = int(input("选择要恢复的备份编号：").strip())
        selected = backups[index - 1]
    except (ValueError, IndexError) as exc:
        raise PfwdError("备份编号无效") from exc
    current_rules, current_bytes = load_rules(config)
    target_bytes = (selected / "rules.tsv").read_bytes()
    target_rules = parse_rules_bytes(target_bytes)
    print_diff(current_rules, target_rules)
    if not confirm_apply():
        print("已取消恢复。")
        return
    new_backup = commit_rules(
        config,
        current_rules,
        current_bytes,
        target_rules,
        f"restore from {selected.name}",
    )
    print(f"✅ 已恢复并应用备份 {selected.name}")
    print(f"恢复前状态另存为：{new_backup}")


def live_view(config: Config) -> None:
    result = nft_command(config, "-a", "list", "table", TABLE_FAMILY, TABLE_NAME)
    if result.returncode != 0:
        raise PfwdError(result.stderr.strip())
    print(result.stdout.rstrip())


def cli_replace_target(config: Config, args: argparse.Namespace) -> None:
    rules, source_bytes = load_rules(config)
    selected_ids = (
        set(selected_ids_with_notice(args.ids, (rule.rule_id for rule in rules)))
        if args.ids
        else None
    )
    old_target = validate_target(args.old_target)
    new_target = validate_target(args.new_target)
    matched = [
        rule
        for rule in rules
        if rule.target == old_target
        and (selected_ids is None or rule.rule_id in selected_ids)
    ]
    if not matched:
        raise PfwdError("没有规则匹配给定旧目标和 ID 范围")
    if args.port == "keep":
        port_mode = "keep"
        fixed_port = None
    elif args.port == "listen":
        port_mode = "listen"
        fixed_port = None
    else:
        try:
            fixed_port = int(args.port)
        except ValueError as exc:
            raise PfwdError("--port 必须是 keep、listen 或 1..65535") from exc
        validate_port(fixed_port)
        port_mode = "fixed"
    matched_ids = {rule.rule_id for rule in matched}
    new_rules: list[Rule] = []
    for rule in rules:
        if rule.rule_id not in matched_ids:
            new_rules.append(rule)
            continue
        if port_mode == "keep":
            target_port = rule.target_port
        elif port_mode == "listen":
            target_port = rule.listen_port
        else:
            assert fixed_port is not None
            target_port = fixed_port
        new_rules.append(
            dataclasses.replace(
                rule, target=new_target, target_port=target_port
            )
        )
    changed = print_diff(rules, new_rules)
    if changed == 0:
        raise PfwdError("没有实际变化")
    if not args.apply:
        print("\nDRY-RUN：未写入。确认后加 --apply；自动化场景另加 --yes。")
        return
    if not args.yes and not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(
        config,
        rules,
        source_bytes,
        new_rules,
        f"replace target {old_target} -> {new_target}",
    )
    print(f"✅ 已安全应用 {changed} 条规则\n备份：{backup}")


def cli_map_file(config: Config, args: argparse.Namespace) -> None:
    rules, source_bytes = load_rules(config)
    path = Path(args.file)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise PfwdError(f"无法读取映射文件：{path}：{exc}") from exc
    mappings = [
        parse_mapping_line(line.strip())
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not mappings:
        raise PfwdError("映射文件没有有效内容")
    new_rules = apply_mappings(rules, mappings)
    changed = print_diff(rules, new_rules)
    if changed == 0:
        raise PfwdError("没有实际变化")
    if not args.apply:
        print("\nDRY-RUN：未写入。确认后加 --apply；自动化场景另加 --yes。")
        return
    if not args.yes and not confirm_apply():
        print("已取消。")
        return
    backup = commit_rules(
        config,
        rules,
        source_bytes,
        new_rules,
        f"apply map file {path}",
    )
    print(f"✅ 已安全应用 {changed} 条映射\n备份：{backup}")


def interactive_menu(config: Config) -> None:
    while True:
        print(f"\n====== pfwd {VERSION}（安全事务版）======")
        print("1) 查看规则")
        print("2) 添加规则并应用")
        print("3) 修改单条并应用")
        print("4) 批量修改目标地址/端口")
        print("5) 批量删除规则")
        print("6) 状态与完整校验")
        print("7) 安全重新应用当前规则")
        print("8) 查看 nft 实时规则")
        print("9) 备份与恢复")
        print("10) 域名 IP 自动刷新")
        print("0) 退出")
        choice = input("选择：").strip()
        try:
            if choice == "1":
                rules, _ = load_rules(config)
                print_rules(rules)
            elif choice == "2":
                add_interactive(config)
            elif choice == "3":
                edit_interactive(config)
            elif choice == "4":
                batch_interactive(config)
            elif choice == "5":
                delete_interactive(config)
            elif choice == "6":
                status_report(config)
            elif choice == "7":
                safe_apply_current(config)
            elif choice == "8":
                live_view(config)
            elif choice == "9":
                backup_restore_interactive(config)
            elif choice == "10":
                print("1) 立即刷新  2) 仅预览  3) 启用每分钟刷新  4) 关闭自动刷新  5) 查看定时器")
                action = input("选择（其他输入返回）：").strip()
                if action in {"1", "2"}:
                    refresh_dns(config, dry_run=action == "2")
                elif action in {"3", "4", "5"}:
                    dns_auto({"3": "enable", "4": "disable", "5": "status"}[action])
            elif choice == "0":
                return
            else:
                print("无效选项")
        except (PfwdError, EOFError, KeyboardInterrupt) as exc:
            if isinstance(exc, (EOFError, KeyboardInterrupt)):
                print("\n已取消当前操作。")
            else:
                print(f"❌ {exc}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pfw",
        description="安全的 nftables TCP/UDP 转发规则管理器",
    )
    parser.add_argument("--version", action="version", version=f"pfwd {VERSION}")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("menu", help="打开交互菜单")
    sub.add_parser("list", help="查看规则源")
    sub.add_parser("status", help="检查规则源、持久化配置和实时 nft 表")
    sub.add_parser("live", help="查看实时 nft 表")
    sub.add_parser("batch", help="进入批量编辑交互")
    sub.add_parser("apply", help="安全重新应用当前规则")
    sub.add_parser("backup", help="创建完整快照")
    sub.add_parser("restore", help="交互式恢复历史快照")
    refresh = sub.add_parser("refresh-dns", help="刷新域名 IP；失败保留旧地址，无变化不写入")
    refresh.add_argument("--dry-run", action="store_true", help="仅预览 DNS 变化")
    auto = sub.add_parser("dns-auto", help="配置每分钟自动 DNS 刷新（systemd）")
    auto.add_argument("action", choices=("enable", "disable", "status"))

    replace = sub.add_parser(
        "replace-target", help="按旧目标精确批量替换；默认仅预览"
    )
    replace.add_argument("old_target")
    replace.add_argument("new_target")
    replace.add_argument(
        "--ids", help="进一步限制 ID，例如 10,12-14"
    )
    replace.add_argument(
        "--port",
        default="keep",
        help="keep（保留）、listen（等于监听端口）或固定端口",
    )
    replace.add_argument("--apply", action="store_true", help="执行应用")
    replace.add_argument(
        "--yes", action="store_true", help="与 --apply 同用，跳过 APPLY 确认"
    )

    mapping = sub.add_parser("map", help="按映射文件逐条批量修改；默认仅预览")
    mapping.add_argument("file", help="每行：ID 新地址 新端口")
    mapping.add_argument("--apply", action="store_true", help="执行应用")
    mapping.add_argument(
        "--yes", action="store_true", help="与 --apply 同用，跳过 APPLY 确认"
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    config = Config.from_env()
    command = args.command or "menu"
    try:
        if command == "refresh-dns":
            refresh_dns(config, dry_run=args.dry_run)
            return 0
        if command == "dns-auto":
            dns_auto(args.action)
            return 0
        if command == "list":
            rules, _ = load_rules(config)
            print_rules(rules)
            return 0
        if command == "status":
            return 0 if status_report(config) else 1
        if command == "live":
            live_view(config)
            return 0
        if command in {"menu", "batch", "apply", "backup", "restore", "replace-target", "map"}:
            require_root()
            if command == "menu":
                interactive_menu(config)
            elif command == "batch":
                batch_interactive(config)
            elif command == "apply":
                safe_apply_current(config)
            elif command == "backup":
                backup = create_backup(config, "manual CLI snapshot")
                print(f"✅ 快照已创建：{backup}")
            elif command == "restore":
                restore_interactive(config)
            elif command == "replace-target":
                cli_replace_target(config, args)
            elif command == "map":
                cli_map_file(config, args)
            return 0
        parser.error(f"未知命令：{command}")
        return 2
    except PfwdError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 1
    except EOFError:
        print("❌ 输入已结束，操作取消。", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
