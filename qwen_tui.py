#!/usr/bin/env python3
from __future__ import annotations

import configparser
import json
import os
import platform
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

# ------------------------------------------------------------
# Bootstrap UI dependency automatically.
# This is intentionally the only package installed before the
# user presses "Install", otherwise we could not render the TUI.
# ------------------------------------------------------------

try:
    from textual import on, work
    from textual.app import App, ComposeResult
    from textual.containers import Container, Horizontal, Vertical, VerticalScroll
    from textual.screen import ModalScreen
    from textual.widgets import (
        Button, Checkbox, Footer, Header, Input, Label,
        Log, Static, Switch
    )
except ImportError:
    print("Installing TUI dependency (textual)...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "textual>=1.0"])
    os.execv(sys.executable, [sys.executable, *sys.argv])


APP_DIR = Path(__file__).resolve().parent
CONFIG_PATH = APP_DIR / "config.ini"
STATE_DIR = APP_DIR / ".state"
INSTALL_LOG = STATE_DIR / "install.log"
ERROR_LOG = STATE_DIR / "errors.log"
SECRETS_PATH = STATE_DIR / "secrets.env"

DEFAULTS = {
    "core": {
        "fake": "1",
        "work_dir": "./qwen-stack",
        "models_dir": "./qwen-stack/models",
        "venv_dir": "./qwen-stack/venv",
        "logs_dir": "./qwen-stack/logs",
    },
    "models": {
        "base_id": "nvidia/Qwen3.8-27B-NVFP4",
        "adapter_id": "msuiche/Qwen3.8-27B-abliterated-cyber-GLP-49",
        "draft_id": "incoai/Qwen3.8-27B-DFlash2",
    },
    "server": {
        "host": "0.0.0.0",
        "port": "8000",
        "context": "262144",
        "mem_fraction": "0.85",
        "draft_tokens": "8",
    },
}

CSS = r"""
Screen {
    background: #000000;
    color: #ededed;
}

#shell {
    width: 100%;
    height: 100%;
    align: center middle;
    padding: 2 4;
}

#main-card {
    width: 92;
    max-width: 96%;
    height: auto;
    padding: 0;
    background: #000000;
}

#topbar {
    height: 3;
    width: 100%;
    padding: 0 1;
    border-bottom: solid #1f1f1f;
}

#brand-left {
    width: 1fr;
    content-align: left middle;
    color: #fafafa;
    text-style: bold;
}

#mode-chip {
    width: auto;
    min-width: 10;
    height: 1;
    margin-top: 1;
    padding: 0 1;
    content-align: center middle;
    background: #111111;
    color: #a1a1aa;
    border: round #2a2a2a;
}

#hero {
    width: 100%;
    height: 8;
    padding: 1 1 0 1;
}

#hero-title {
    height: 3;
    color: #fafafa;
    text-style: bold;
    content-align: left middle;
}

#hero-copy {
    color: #737373;
    content-align: left top;
}

#menu-grid {
    width: 100%;
    height: auto;
    padding: 0 1;
}

.menu-row {
    width: 100%;
    height: 7;
}

.menu-btn {
    width: 1fr;
    height: 6;
    margin-right: 1;
    padding: 0 2;
    background: #0a0a0a;
    color: #e5e5e5;
    border: round #262626;
    text-style: bold;
    content-align: left middle;
}

#install-btn,
#exit-btn {
    margin-right: 0;
}

.menu-btn:hover {
    background: #111111;
    border: round #525252;
    color: #ffffff;
}

.menu-btn:focus {
    background: #0f0f0f;
    border: round #fafafa;
    color: #ffffff;
}

#install-btn {
    border: round #3f3f46;
}

#install-btn:hover,
#install-btn:focus {
    border: round #fafafa;
}

#logs-btn {
    color: #d4d4d8;
}

#exit-btn {
    color: #a3a3a3;
}

#exit-btn:hover,
#exit-btn:focus {
    color: #f87171;
    border: round #7f1d1d;
}

#statusbar {
    width: 100%;
    height: 4;
    margin-top: 1;
    padding: 0 1;
    border-top: solid #1f1f1f;
    color: #737373;
}

#status-line {
    width: 1fr;
    content-align: left middle;
    color: #737373;
}

#hint-line {
    width: auto;
    content-align: right middle;
    color: #525252;
}

ModalScreen {
    align: center middle;
    background: rgba(0,0,0,0.82);
}

.modal {
    width: 82;
    max-width: 94%;
    max-height: 88%;
    padding: 1 2 2 2;
    background: #090909;
    border: round #2a2a2a;
}

.modal-title {
    width: 100%;
    height: 4;
    content-align: left middle;
    text-style: bold;
    color: #fafafa;
    border-bottom: solid #1f1f1f;
    margin-bottom: 1;
}

.field-label {
    margin-top: 1;
    margin-bottom: 0;
    color: #a3a3a3;
}

Input {
    height: 3;
    background: #050505;
    color: #ededed;
    border: round #262626;
    padding: 0 1;
}

Input:hover {
    border: round #404040;
}

Input:focus {
    border: round #fafafa;
}

.switch-row {
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

.actions {
    width: 100%;
    height: 4;
    margin-top: 2;
    align-horizontal: right;
}

.actions Button {
    width: auto;
    min-width: 14;
    height: 3;
    margin-left: 1;
    border: round #2a2a2a;
    background: #0a0a0a;
    color: #d4d4d8;
}

.actions Button:hover,
.actions Button:focus {
    border: round #fafafa;
    color: #ffffff;
}

#save-btn,
#start-install {
    background: #fafafa;
    color: #090909;
    border: round #fafafa;
    text-style: bold;
}

#save-btn:hover,
#save-btn:focus,
#start-install:hover,
#start-install:focus {
    background: #d4d4d4;
    color: #000000;
    border: round #ffffff;
}

#progress-status {
    height: 4;
    margin-bottom: 1;
    padding: 0 1;
    content-align: left middle;
    background: #050505;
    color: #d4d4d8;
    border: round #1f1f1f;
}

#install-log,
#log-view {
    height: 30;
    padding: 1;
    background: #030303;
    color: #d4d4d8;
    border: round #1f1f1f;
}

Log {
    scrollbar-color: #333333;
    scrollbar-color-hover: #555555;
    scrollbar-color-active: #737373;
    scrollbar-background: #090909;
}

.notification {
    background: #111111;
    color: #fafafa;
    border: round #2a2a2a;
}
"""


def boolv(value: str) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def ensure_config() -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    if CONFIG_PATH.exists():
        cfg.read(CONFIG_PATH)

    changed = False
    for section, vals in DEFAULTS.items():
        if section not in cfg:
            cfg[section] = {}
            changed = True
        for key, val in vals.items():
            if key not in cfg[section]:
                cfg[section][key] = val
                changed = True

    if changed or not CONFIG_PATH.exists():
        with CONFIG_PATH.open("w", encoding="utf-8") as f:
            cfg.write(f)
    return cfg


def save_config(cfg: configparser.ConfigParser) -> None:
    with CONFIG_PATH.open("w", encoding="utf-8") as f:
        cfg.write(f)


def load_secrets() -> dict[str, str]:
    out = {}
    if SECRETS_PATH.exists():
        for line in SECRETS_PATH.read_text(encoding="utf-8").splitlines():
            if "=" not in line or line.lstrip().startswith("#"):
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def save_secrets(hf_token: str, api_key: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    SECRETS_PATH.write_text(
        f"HF_TOKEN={hf_token}\nSGLANG_API_KEY={api_key}\n",
        encoding="utf-8",
    )
    try:
        os.chmod(SECRETS_PATH, 0o600)
    except Exception:
        pass


class SetupScreen(ModalScreen):
    def compose(self) -> ComposeResult:
        cfg = ensure_config()
        sec = load_secrets()

        with VerticalScroll(classes="modal"):
            yield Static("Setup", classes="modal-title")

            yield Static("Hugging Face token", classes="field-label")
            yield Input(
                value=sec.get("HF_TOKEN", ""),
                password=True,
                placeholder="hf_...",
                id="hf-token",
            )

            yield Static("API key", classes="field-label")
            api_key = sec.get("SGLANG_API_KEY") or ("sk-" + secrets.token_hex(32))
            yield Input(value=api_key, password=True, id="api-key")

            yield Static("Server port", classes="field-label")
            yield Input(value=cfg["server"]["port"], id="port")


            with Horizontal(classes="switch-row"):
                yield Label("Fake mode")
                yield Switch(value=boolv(cfg["core"]["fake"]), id="fake")


            with Horizontal(classes="actions"):
                yield Button("Save changes", id="save-btn")
                yield Button("Cancel", id="close-btn")

    @on(Button.Pressed, "#save-btn")
    def save(self) -> None:
        cfg = ensure_config()

        cfg["core"]["fake"] = "1" if self.query_one("#fake", Switch).value else "0"
        cfg["server"]["port"] = self.query_one("#port", Input).value.strip() or "8000"

        save_config(cfg)
        save_secrets(
            self.query_one("#hf-token", Input).value.strip(),
            self.query_one("#api-key", Input).value.strip(),
        )
        self.app.notify("Setup saved", severity="information")
        self.dismiss()

    @on(Button.Pressed, "#close-btn")
    def close(self) -> None:
        self.dismiss()


class LogsScreen(ModalScreen):
    def compose(self) -> ComposeResult:
        with Vertical(classes="modal"):
            yield Static("Logs / Errors", classes="modal-title")
            yield Log(id="log-view", auto_scroll=True, highlight=True)
            with Horizontal(classes="actions"):
                yield Button("Refresh", id="refresh-logs")
                yield Button("Clear errors", id="clear-errors")
                yield Button("Close", id="close-logs")

    def on_mount(self) -> None:
        self.refresh_logs()

    def refresh_logs(self) -> None:
        log = self.query_one("#log-view", Log)
        log.clear()

        if INSTALL_LOG.exists():
            log.write_line("[INSTALL LOG]")
            for line in INSTALL_LOG.read_text(encoding="utf-8", errors="replace").splitlines()[-300:]:
                log.write_line(line)
        else:
            log.write_line("No install log yet.")

        log.write_line("")
        log.write_line("[ERRORS]")
        if ERROR_LOG.exists() and ERROR_LOG.stat().st_size:
            for line in ERROR_LOG.read_text(encoding="utf-8", errors="replace").splitlines()[-150:]:
                log.write_line(line)
        else:
            log.write_line("No errors.")

    @on(Button.Pressed, "#refresh-logs")
    def refresh_clicked(self) -> None:
        self.refresh_logs()

    @on(Button.Pressed, "#clear-errors")
    def clear_errors(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        ERROR_LOG.write_text("", encoding="utf-8")
        self.refresh_logs()

    @on(Button.Pressed, "#close-logs")
    def close(self) -> None:
        self.dismiss()


class InstallScreen(ModalScreen):
    def compose(self) -> ComposeResult:
        with Vertical(classes="modal"):
            yield Static("Install", classes="modal-title")
            yield Static("Ready", id="progress-status")
            yield Log(id="install-log", auto_scroll=True, highlight=True)
            with Horizontal(classes="actions"):
                yield Button("Run install", id="start-install")
                yield Button("Close", id="close-install")

    def on_mount(self) -> None:
        self._append("Ready. In fake mode nothing destructive is executed.", "info")

    def _dispatch_ui(self, callback, *args) -> None:
        """
        Run a UI callback directly when already on Textual's app thread,
        otherwise marshal it back from a worker thread.
        """
        app_thread_id = getattr(self.app, "_thread_id", None)
        if app_thread_id == threading.get_ident():
            callback(*args)
        else:
            self.app.call_from_thread(callback, *args)

    def _append(self, message: str, level: str = "info") -> None:
        prefix = {
            "info": "[INFO]",
            "ok": "[OK]",
            "warn": "[WARN]",
            "error": "[ERROR]",
            "cmd": "[CMD]",
        }.get(level, "[INFO]")
        log_widget = self.query_one("#install-log", Log)
        self._dispatch_ui(log_widget.write_line, f"{prefix} {message}")

    def _status(self, message: str) -> None:
        status_widget = self.query_one("#progress-status", Static)
        self._dispatch_ui(status_widget.update, message)

    @on(Button.Pressed, "#start-install")
    def start_clicked(self) -> None:
        self.query_one("#start-install", Button).disabled = True
        self.query_one("#close-install", Button).disabled = True
        self.run_install()

    @work(thread=True, exclusive=True)
    def run_install(self) -> None:
        installer = Installer(self._append, self._status)
        try:
            installer.run_all()
            self._status("[green]Install completed[/]")
            self._append("Full pipeline completed.", "ok")
        except Exception as exc:
            self._status("[red]Install failed[/]")
            self._append(str(exc), "error")
        finally:
            self._dispatch_ui(setattr, self.query_one("#start-install", Button), "disabled", False)
            self._dispatch_ui(setattr, self.query_one("#close-install", Button), "disabled", False)

    @on(Button.Pressed, "#close-install")
    def close(self) -> None:
        self.dismiss()


class Installer:
    def __init__(self, log_cb: Callable[[str, str], None], status_cb: Callable[[str], None]):
        self.log_cb = log_cb
        self.status_cb = status_cb
        self.cfg = ensure_config()
        self.fake = boolv(self.cfg["core"]["fake"])

        self.work = (APP_DIR / self.cfg["core"]["work_dir"]).resolve()
        self.models = (APP_DIR / self.cfg["core"]["models_dir"]).resolve()
        self.venv = (APP_DIR / self.cfg["core"]["venv_dir"]).resolve()
        self.logs = (APP_DIR / self.cfg["core"]["logs_dir"]).resolve()

        self.base_dir = self.models / "Qwen3.8-27B-NVFP4"
        self.adapter_dir = self.models / "weightless"
        self.draft_dir = self.models / "Qwen3.8-27B-DFlash2"

        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.work.mkdir(parents=True, exist_ok=True)
        self.models.mkdir(parents=True, exist_ok=True)
        self.logs.mkdir(parents=True, exist_ok=True)

    def log(self, msg: str, level: str = "info") -> None:
        self.log_cb(msg, level)
        with INSTALL_LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + f"{level.upper()}: {msg}\n")

    def fail(self, msg: str) -> None:
        with ERROR_LOG.open("a", encoding="utf-8") as f:
            f.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg + "\n")
        raise RuntimeError(msg)

    def run(self, cmd: list[str] | str, *, env=None, check=True) -> subprocess.CompletedProcess:
        rendered = cmd if isinstance(cmd, str) else shlex.join(str(x) for x in cmd)
        self.log(rendered, "cmd")

        if self.fake:
            time.sleep(0.08)
            return subprocess.CompletedProcess(cmd, 0, "", "")

        if isinstance(cmd, str):
            proc = subprocess.run(cmd, shell=True, text=True, capture_output=True, env=env)
        else:
            proc = subprocess.run(cmd, text=True, capture_output=True, env=env)

        if proc.stdout:
            for line in proc.stdout.splitlines():
                self.log(line, "info")
        if proc.stderr:
            for line in proc.stderr.splitlines():
                self.log(line, "warn")

        if check and proc.returncode != 0:
            self.fail(f"Command failed ({proc.returncode}): {rendered}")
        return proc

    def stage(self, title: str) -> None:
        self.status_cb(title)
        self.log(f"--- {title} ---", "info")

    def require_root(self) -> None:
        if self.fake:
            return
        if platform.system() != "Linux":
            self.fail("Real mode supports Linux only.")
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.fail("Run real mode with sudo/root.")

    def preflight(self) -> None:
        self.stage("1/8 Preflight")
        self.log(f"OS: {platform.system()} {platform.release()}")
        self.log(f"Python: {platform.python_version()}")
        self.log(f"Fake mode: {self.fake}", "warn" if self.fake else "ok")

        if not self.fake:
            gpu = self.run(
                ["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader"],
                check=False,
            )
            if gpu.returncode != 0:
                self.fail("nvidia-smi failed. Use a proper NVIDIA/CUDA cloud image.")
            self.log("NVIDIA GPU detected.", "ok")

    def system_packages(self) -> None:
        self.stage("2/8 System packages")
        self.run(["apt-get", "update"])
        self.run([
            "apt-get", "install", "-y",
            "git", "curl", "wget", "jq", "ca-certificates",
            "build-essential", "python3", "python3-venv",
            "python3-pip", "tmux", "htop",
        ])

        # Headers only: do not replace rented-cloud kernels blindly.
        if not self.fake:
            kernel = subprocess.check_output(["uname", "-r"], text=True).strip()
            self.run(["apt-get", "install", "-y", f"linux-headers-{kernel}"], check=False)
        else:
            self.run(["apt-get", "install", "-y", "linux-headers-$(uname -r)"])

    def python_stack(self) -> None:
        self.stage("3/8 Python + SGLang")
        self.run(["python3", "-m", "venv", str(self.venv)])
        pip = self.venv / "bin" / "pip"
        python = self.venv / "bin" / "python"

        self.run([str(pip), "install", "-U", "pip", "uv"])
        self.run([
            str(pip), "install", "-U",
            "sglang",
            "huggingface_hub[cli]",
        ])

        if not self.fake:
            verify = (
                "import torch, sglang; "
                "print('torch', torch.__version__); "
                "print('cuda', torch.version.cuda); "
                "print('cuda_available', torch.cuda.is_available()); "
                "assert torch.cuda.is_available()"
            )
            self.run([str(python), "-c", verify])
        else:
            self.log("CUDA/SGLang verification simulated.", "ok")

    def weightless_repo(self) -> None:
        self.stage("4/8 Weightless")
        dst = self.work / "weightless"
        if self.fake:
            self.run(["git", "clone", "--depth", "1", "https://github.com/msuiche/weightless", str(dst)])
            dst.mkdir(parents=True, exist_ok=True)
            (dst / "FAKE").write_text("1\n")
            return

        if (dst / ".git").exists():
            self.run(["git", "-C", str(dst), "pull", "--ff-only"])
        else:
            self.run(["git", "clone", "--depth", "1", "https://github.com/msuiche/weightless", str(dst)])

    def hf_download(self, model_id: str, dest: Path, include: list[str] | None = None) -> None:
        if self.fake:
            self.log(f"FAKE download: {model_id} -> {dest}", "warn")
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "FAKE_MODEL.txt").write_text(model_id + "\n", encoding="utf-8")
            if include:
                for name in include:
                    p = dest / name
                    p.write_text("{}\n" if name.endswith(".json") else "FAKE\n", encoding="utf-8")
            return

        hf = self.venv / "bin" / "hf"
        env = os.environ.copy()
        sec = load_secrets()
        if sec.get("HF_TOKEN"):
            env["HF_TOKEN"] = sec["HF_TOKEN"]

        cmd = [str(hf), "download", model_id]
        if include:
            cmd.extend(include)
        cmd.extend(["--local-dir", str(dest)])
        self.run(cmd, env=env)

    def models_download(self) -> None:
        self.stage("5/8 Models")
        self.hf_download(self.cfg["models"]["base_id"], self.base_dir)

        self.hf_download(
            self.cfg["models"]["adapter_id"],
            self.adapter_dir,
            ["adapter_config.json", "adapter_model.safetensors"],
        )

        self.hf_download(self.cfg["models"]["draft_id"], self.draft_dir)

    def create_start_script(self) -> None:
        self.stage("6/8 Server configuration")
        sec = load_secrets()
        api_key = sec.get("SGLANG_API_KEY")
        if not api_key:
            api_key = "sk-" + secrets.token_hex(32)
            save_secrets(sec.get("HF_TOKEN", ""), api_key)

        s = self.cfg["server"]
        script = self.work / "start_server.sh"

        body = f"""#!/usr/bin/env bash
set -euo pipefail
source {shlex.quote(str(SECRETS_PATH))}
export HF_HOME={shlex.quote(str(self.models / ".hf"))}

exec {shlex.quote(str(self.venv / "bin" / "python"))} -m sglang.launch_server \\
  --model-path {shlex.quote(str(self.base_dir))} \\
  --served-model-name qwen \\
  --host {shlex.quote(s["host"])} \\
  --port {shlex.quote(s["port"])} \\
  --context-length {shlex.quote(s["context"])} \\
  --mem-fraction-static {shlex.quote(s["mem_fraction"])} \\
  --attention-backend flashinfer \\
  --kv-cache-dtype fp8_e4m3 \\
  --chunked-prefill-size 2048 \\
  --max-running-requests 1 \\
  --reasoning-parser qwen3 \\
  --tool-call-parser qwen3_coder \\
  --enable-lora \\
  --lora-paths weightless={shlex.quote(str(self.adapter_dir))} \\
  --max-loras-per-batch 2 \\
  --speculative-algorithm DFLASH \\
  --speculative-draft-model-path {shlex.quote(str(self.draft_dir))} \\
  --speculative-draft-model-quantization unquant \\
  --speculative-num-draft-tokens {shlex.quote(s["draft_tokens"])} \\
  --mamba-radix-cache-strategy extra_buffer \\
  --mamba-ssm-dtype bfloat16 \\
  --enable-metrics \\
  --trust-remote-code \\
  --api-key "$SGLANG_API_KEY"
"""
        script.write_text(body, encoding="utf-8")
        os.chmod(script, 0o700)
        self.log(f"Generated {script}", "ok")

    def systemd_service(self) -> None:
        self.stage("7/8 systemd")
        start_script = self.work / "start_server.sh"
        unit = f"""[Unit]
Description=Qwen3.8 NVFP4 Weightless SGLang
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory={self.work}
ExecStart={start_script}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
"""
        preview = self.work / "qwen-sglang.service"
        preview.write_text(unit, encoding="utf-8")

        if self.fake:
            self.run(["cp", str(preview), "/etc/systemd/system/qwen-sglang.service"])
            self.run(["systemctl", "daemon-reload"])
            self.run(["systemctl", "enable", "qwen-sglang"])
            return

        Path("/etc/systemd/system/qwen-sglang.service").write_text(unit, encoding="utf-8")
        self.run(["systemctl", "daemon-reload"])
        self.run(["systemctl", "enable", "qwen-sglang"])

    def finish(self) -> None:
        self.stage("8/8 Final")
        if self.fake:
            self.log("FAKE install complete. No real packages/models/systemd changes were made.", "ok")
            self.log("Switch Fake mode OFF in Setup when you move to the GPU host.", "warn")
        else:
            self.run(["systemctl", "restart", "qwen-sglang"])
            self.log("qwen-sglang started.", "ok")
            self.log("Use Logs / Errors to inspect startup.", "info")

    def run_all(self) -> None:
        self.require_root()
        try:
            self.preflight()
            self.system_packages()
            self.python_stack()
            self.weightless_repo()
            self.models_download()
            self.create_start_script()
            self.systemd_service()
            self.finish()
        except Exception as exc:
            with ERROR_LOG.open("a", encoding="utf-8") as f:
                f.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + repr(exc) + "\n")
            raise


class QwenTUI(App):
    CSS = CSS
    TITLE = "Qwen Stack"
    SUB_TITLE = "NVFP4 • Weightless • DFlash2 • SGLang"

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("s", "setup", "Setup"),
        ("i", "install", "Install"),
        ("l", "logs", "Logs"),
    ]

    def compose(self) -> ComposeResult:
        cfg = ensure_config()
        fake = boolv(cfg["core"]["fake"])

        with Container(id="shell"):
            with Vertical(id="main-card"):
                with Horizontal(id="topbar"):
                    yield Static("Qwen Stack", id="brand-left")
                    yield Static("FAKE" if fake else "REAL", id="mode-chip")

                with Vertical(id="hero"):
                    yield Static("Inference stack, automated.", id="hero-title")
                    yield Static(
                        "Qwen3.8 NVFP4 · Weightless · DFlash2 · SGLang\n"
                        "Configure once, deploy the full runtime in one pass.",
                        id="hero-copy",
                    )

                with Vertical(id="menu-grid"):
                    with Horizontal(classes="menu-row"):
                        yield Button("Setup\nHF token · API key · runtime", id="setup-btn", classes="menu-btn")
                        yield Button("Install\nProvision · models · service", id="install-btn", classes="menu-btn")
                    with Horizontal(classes="menu-row"):
                        yield Button("Logs / Errors\nInstall output · failures", id="logs-btn", classes="menu-btn")
                        yield Button("Exit\nClose Qwen Stack", id="exit-btn", classes="menu-btn")

                with Horizontal(id="statusbar"):
                    yield Static(
                        self._status_text(cfg, fake),
                        id="status-line",
                    )
                    yield Static("S setup   I install   L logs   Q quit", id="hint-line")

    def _status_text(self, cfg: configparser.ConfigParser, fake: bool) -> str:
        mode = "[yellow]FAKE[/]" if fake else "[green]REAL[/]"
        ctx = int(cfg["server"]["context"])
        ctx_text = f"{ctx // 1024}K" if ctx >= 1024 else str(ctx)
        return f"Mode {mode}   ·   Port {cfg['server']['port']}   ·   Context {ctx_text}"

    def refresh_status(self) -> None:
        cfg = ensure_config()
        fake = boolv(cfg["core"]["fake"])
        self.query_one("#mode-chip", Static).update("FAKE" if fake else "REAL")
        self.query_one("#status-line", Static).update(self._status_text(cfg, fake))

    @on(Button.Pressed, "#setup-btn")
    def open_setup(self) -> None:
        self.push_screen(SetupScreen(), callback=lambda _: self.refresh_status())

    @on(Button.Pressed, "#install-btn")
    def open_install(self) -> None:
        self.push_screen(InstallScreen())

    @on(Button.Pressed, "#logs-btn")
    def open_logs(self) -> None:
        self.push_screen(LogsScreen())

    @on(Button.Pressed, "#exit-btn")
    def exit_app(self) -> None:
        self.exit()

    def action_setup(self) -> None:
        self.open_setup()

    def action_install(self) -> None:
        self.open_install()

    def action_logs(self) -> None:
        self.open_logs()


if __name__ == "__main__":
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    ensure_config()
    QwenTUI().run()
