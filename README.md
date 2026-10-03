# Qwen Stack TUI v4 — Vercel-style

TUI minimale:

```text
Setup
Install
Logs / Errors
Exit
```

## Importantissimo: networking

Questa versione **NON tocca il firewall**.

Non esegue:

```text
ufw reset
ufw enable
ufw allow
iptables
nftables
```

e non modifica le regole di rete del provider.

La porta configurata per SGLang viene semplicemente usata dal server. La gestione dell'esposizione pubblica resta al provider / security group / port mapping / reverse proxy.

## Run

```bash
python3 qwen_tui.py
```

La prima esecuzione installa automaticamente solo `textual`, necessario per mostrare la TUI.

## Fake mode

Parte con:

```ini
fake = 1
```

`Install` simula:

- apt packages
- kernel headers
- SGLang
- Weightless repo
- Qwen3.8-27B NVFP4
- Weightless LoRA
- DFlash2
- systemd

senza scaricare modelli o modificare il sistema.

## Real mode

In `Setup` spegni `Fake mode`, poi:

```bash
sudo python3 qwen_tui.py
```

`Install` esegue tutta la pipeline.

## Setup

Configura soltanto:

- Hugging Face token
- API key
- porta API
- fake/real mode

I secret vengono salvati in `.state/secrets.env` con permessi `0600`.

## Stack finale

```text
nvidia/Qwen3.8-27B-NVFP4
          +
Weightless rank-1 LoRA
          +
incoai/Qwen3.8-27B-DFlash2
          ↓
SGLang
          ↓
FlashInfer + FP8 KV
          ↓
OpenAI-compatible API
```

## Kernel

Non sostituisce automaticamente il kernel del provider.
Installa solo gli header del kernel corrente.


## UI v4

Monochrome Vercel-style theme, rounded cards, 2×2 dashboard, polished modals and focus states.


## v4.1 fix

Fixed Textual main-thread/worker-thread dispatch in the Install modal (`call_from_thread` crash on Windows).
