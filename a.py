#!/usr/bin/env python3
from __future__ import annotations

import py_compile
import shutil
import sys
from pathlib import Path

TARGET = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("qwen_tui.py")
BACKUP = TARGET.with_suffix(TARGET.suffix + ".bak")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"{label}: expected exactly 1 match, found {count}. "
            "The upstream qwen_tui.py probably changed."
        )
    return text.replace(old, new, 1)


if not TARGET.exists():
    raise SystemExit(f"File not found: {TARGET.resolve()}")

src = TARGET.read_text(encoding="utf-8")
shutil.copy2(TARGET, BACKUP)

src = replace_once(
    src,
    '''    "core": {
        "fake": "1",
        "work_dir": "./qwen-stack",''',
    '''    "core": {
        "work_dir": "./qwen-stack",''',
    "DEFAULTS fake option",
)

src = replace_once(
    src,
    '''    from textual.widgets import (
        Button, Checkbox, Footer, Header, Input, Label,
        Log, Static, Switch
    )''',
    '''    from textual.widgets import (
        Button, Checkbox, Footer, Header, Input,
        Log, Static
    )''',
    "Textual fake-mode widgets",
)

src = replace_once(
    src,
    '''.switch-row {
    width: 100%;
    height: 4;
    margin-top: 1;
    padding: 0 1;
    background: #050505;
    border: round #1f1f1f;
    content-align: left middle;
}

Switch {
    margin-left: 2;
}
''',
    "",
    "Fake-mode CSS",
)

src = replace_once(
    src,
    '''def boolv(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}

''',
    "",
    "boolv helper",
)

src = replace_once(
    src,
    '''
            with Horizontal(classes="switch-row"):
                yield Label("Fake mode")
                yield Switch(value=boolv(cfg["core"]["fake"]), id="fake")
''',
    "",
    "Setup fake toggle",
)

src = replace_once(
    src,
    '''        cfg["core"]["fake"] = "1" if self.query_one("#fake", Switch).value else "0"
        cfg["server"]["port"] = self.query_one("#port", Input).value.strip() or "8000"''',
    '''        cfg["server"]["port"] = self.query_one("#port", Input).value.strip() or "8000"''',
    "Setup fake save",
)

src = replace_once(
    src,
    '''        self._append("Ready. In fake mode nothing destructive is executed.", "info")''',
    '''        self._append("Ready. REAL mode: installation commands will be executed on this host.", "warn")''',
    "Install screen fake notice",
)

src = replace_once(
    src,
    '''        self.cfg = ensure_config()
        self.fake = boolv(self.cfg["core"]["fake"])
        self.work = (APP_DIR / self.cfg["core"]["work_dir"]).resolve()''',
    '''        self.cfg = ensure_config()
        self.work = (APP_DIR / self.cfg["core"]["work_dir"]).resolve()''',
    "Installer fake state",
)

src = replace_once(
    src,
    '''        if self.fake:
            time.sleep(0.08)
            return subprocess.CompletedProcess(cmd, 0, "", "")

''',
    "",
    "Fake command executor",
)

src = replace_once(
    src,
    '''    def require_root(self) -> None:
        if self.fake:
            return
        if platform.system() != "Linux":
            self.fail("Real mode supports Linux only.")
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.fail("Run real mode with sudo/root.")''',
    '''    def require_root(self) -> None:
        if platform.system() != "Linux":
            self.fail("Installer supports Linux only.")
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.fail("Run the installer with sudo/root.")''',
    "Fake root bypass",
)

src = replace_once(
    src,
    '''        self.log(f"Python: {platform.python_version()}")
        self.log(f"Fake mode: {self.fake}", "warn" if self.fake else "ok")
        if not self.fake:
            gpu = self.run(
                ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader"],
                check=False,
            )
            if gpu.returncode != 0:
                self.fail("nvidia-smi failed. Use a proper NVIDIA/CUDA cloud image.")
            self.log("NVIDIA GPU detected.", "ok")''',
    '''        self.log(f"Python: {platform.python_version()}")
        self.log("Mode: REAL", "ok")
        gpu = self.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader"],
            check=False,
        )
        if gpu.returncode != 0:
            self.fail("nvidia-smi failed. Use a proper NVIDIA/CUDA cloud image.")
        self.log("NVIDIA GPU detected.", "ok")''',
    "Fake preflight branch",
)

src = replace_once(
    src,
    '''        # Headers only: do not replace rented-cloud kernels blindly.
        if not self.fake:
            kernel = subprocess.check_output(["uname", "-r"], text=True).strip()
            self.run(["apt-get", "install", "-y", f"linux-headers-{kernel}"], check=False)
        else:
            self.run(["apt-get", "install", "-y", "linux-headers-$(uname -r)"])''',
    '''        # Headers only: do not replace rented-cloud kernels blindly.
        kernel = subprocess.check_output(["uname", "-r"], text=True).strip()
        self.run(["apt-get", "install", "-y", f"linux-headers-{kernel}"], check=False)''',
    "Fake kernel-header branch",
)

src = replace_once(
    src,
    '''        if not self.fake:
            verify = (
                "import torch, sglang; "
                "print('torch', torch.__version__); "
                "print('cuda', torch.version.cuda); "
                "print('cuda_available', torch.cuda.is_available()); "
                "assert torch.cuda.is_available()"
            )
            self.run([str(python), "-c", verify])
        else:
            self.log("CUDA/SGLang verification simulated.", "ok")''',
    '''        verify = (
            "import torch, sglang; "
            "print('torch', torch.__version__); "
            "print('cuda', torch.version.cuda); "
            "print('cuda_available', torch.cuda.is_available()); "
            "assert torch.cuda.is_available()"
        )
        self.run([str(python), "-c", verify])''',
    "Fake CUDA verification branch",
)

src = replace_once(
    src,
    '''        if self.fake:
            self.run(["git", "clone", "--depth", "1", "https://github.com/msuiche/weightless", str(dst)])
            dst.mkdir(parents=True, exist_ok=True)
            (dst / "FAKE").write_text("1\\n")
            return
''',
    "",
    "Fake Weightless branch",
)

src = replace_once(
    src,
    '''        if self.fake:
            self.log(f"FAKE download: {model_id} -> {dest}", "warn")
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "FAKE_MODEL.txt").write_text(model_id + "\\n", encoding="utf-8")
            if include:
                for name in include:
                    p = dest / name
                    p.write_text("{}\\n" if name.endswith(".json") else "FAKE\\n", encoding="utf-8")
            return
''',
    "",
    "Fake model-download branch",
)

src = replace_once(
    src,
    '''        if self.fake:
            self.run(["cp", str(preview), "/etc/systemd/system/qwen-sglang.service"])
            self.run(["systemctl", "daemon-reload"])
            self.run(["systemctl", "enable", "qwen-sglang"])
            return

''',
    "",
    "Fake systemd branch",
)

src = replace_once(
    src,
    '''        if self.fake:
            self.log("FAKE install complete. No real packages/models/systemd changes were made.", "ok")
            self.log("Switch Fake mode OFF in Setup when you move to the GPU host.", "warn")
        else:
            self.run(["systemctl", "restart", "qwen-sglang"])
            self.log("qwen-sglang started.", "ok")
            self.log("Use Logs / Errors to inspect startup.", "info")''',
    '''        self.run(["systemctl", "restart", "qwen-sglang"])
        self.log("qwen-sglang started.", "ok")
        self.log("Use Logs / Errors to inspect startup.", "info")''',
    "Fake finish branch",
)

src = replace_once(
    src,
    '''    def compose(self) -> ComposeResult:
        cfg = ensure_config()
        fake = boolv(cfg["core"]["fake"])
        with Container(id="shell"):''',
    '''    def compose(self) -> ComposeResult:
        cfg = ensure_config()
        with Container(id="shell"):''',
    "UI fake state",
)

src = replace_once(
    src,
    '''                    yield Static("FAKE" if fake else "REAL", id="mode-chip")''',
    '''                    yield Static("REAL", id="mode-chip")''',
    "UI mode chip",
)

src = replace_once(
    src,
    '''                        self._status_text(cfg, fake),''',
    '''                        self._status_text(cfg),''',
    "UI status call",
)

src = replace_once(
    src,
    '''    def _status_text(self, cfg: configparser.ConfigParser, fake: bool) -> str:
        mode = "[yellow]FAKE[/]" if fake else "[green]REAL[/]"
        ctx = int(cfg["server"]["context"])
        ctx_text = f"{ctx // 1024}K" if ctx >= 1024 else str(ctx)
        return f"Mode {mode}   ·   Port {cfg['server']['port']}   ·   Context {ctx_text}"
    def refresh_status(self) -> None:
        cfg = ensure_config()
        fake = boolv(cfg["core"]["fake"])
        self.query_one("#mode-chip", Static).update("FAKE" if fake else "REAL")
        self.query_one("#status-line", Static).update(self._status_text(cfg, fake))''',
    '''    def _status_text(self, cfg: configparser.ConfigParser) -> str:
        mode = "[green]REAL[/]"
        ctx = int(cfg["server"]["context"])
        ctx_text = f"{ctx // 1024}K" if ctx >= 1024 else str(ctx)
        return f"Mode {mode}   ·   Port {cfg['server']['port']}   ·   Context {ctx_text}"

    def refresh_status(self) -> None:
        cfg = ensure_config()
        self.query_one("#mode-chip", Static).update("REAL")
        self.query_one("#status-line", Static).update(self._status_text(cfg))''',
    "UI fake status logic",
)

for forbidden in (
    "self.fake",
    '["core"]["fake"]',
    'id="fake"',
    "fake mode",
    "fake_model",
):
    if forbidden in src.lower():
        raise RuntimeError(f"Leftover Fake-mode code detected: {forbidden!r}")

compile(src, str(TARGET), "exec")
TARGET.write_text(src, encoding="utf-8")
py_compile.compile(str(TARGET), doraise=True)

print(f"[OK] REAL-only qwen_tui.py written: {TARGET.resolve()}")
print(f"[OK] Backup preserved at:          {BACKUP.resolve()}")
print("[OK] Python syntax check passed.")
print()
print("Run it with:")
print(f"  sudo {sys.executable} {TARGET}")
