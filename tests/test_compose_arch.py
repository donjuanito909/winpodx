"""Architecture-aware compose template generation tests.

Issue #141 Phase 2: the QEMU ``ARGUMENTS:`` value must differ between
x86_64 and aarch64 hosts. On x86_64 we pass
``-cpu host,arch_capabilities=off``; on aarch64 the ``arch_capabilities``
sub-option doesn't exist and crashes QEMU at boot (issue #140), so we
emit only ``-cpu host``.
"""

from __future__ import annotations

import winpodx.core.config as _config_module
import winpodx.core.pod.compose as _compose_module
from winpodx.core.config import Config
from winpodx.core.pod.compose import _build_compose_content


def _cfg() -> Config:
    cfg = Config()
    cfg.pod.backend = "podman"
    cfg.rdp.user = "User"
    cfg.rdp.password = "TestPassword1!"
    cfg.rdp.port = 3390
    cfg.pod.vnc_port = 8007
    cfg.pod.container_name = "winpodx-windows"
    return cfg


def test_compose_arguments_x86_64(monkeypatch):
    """x86_64 hosts emit ``-cpu host,arch_capabilities=off``."""
    monkeypatch.setattr(_compose_module.platform, "machine", lambda: "x86_64")
    monkeypatch.setattr(_config_module.platform, "machine", lambda: "x86_64")
    content = _build_compose_content(_cfg())
    assert 'ARGUMENTS: "-cpu host,arch_capabilities=off"' in content


def test_compose_arguments_aarch64(monkeypatch):
    """aarch64 hosts emit ``-cpu host`` only (no arch_capabilities).

    Regression guard for issue #140: passing ``arch_capabilities=off`` on
    aarch64 crashes QEMU with ``Property 'host-arm-cpu.arch_capabilities'
    not found``.
    """
    monkeypatch.setattr(_compose_module.platform, "machine", lambda: "aarch64")
    monkeypatch.setattr(_config_module.platform, "machine", lambda: "aarch64")
    content = _build_compose_content(_cfg())
    assert 'ARGUMENTS: "-cpu host"' in content
    assert "arch_capabilities" not in content


def test_compose_arguments_unknown_arch_falls_through_to_x86(monkeypatch):
    """Unknown / unexpected machine() value falls through to the x86_64
    behaviour. This is intentional: an unsupported platform should get the
    "wrong" arguments and surface a clear QEMU error at pod start rather
    than silently using a partially-correct ARM config.
    """
    monkeypatch.setattr(_compose_module.platform, "machine", lambda: "riscv64")
    monkeypatch.setattr(_config_module.platform, "machine", lambda: "riscv64")
    content = _build_compose_content(_cfg())
    assert 'ARGUMENTS: "-cpu host,arch_capabilities=off"' in content
