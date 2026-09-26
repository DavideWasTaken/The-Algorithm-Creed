# Windows operation

The runtime needs an interactive Windows desktop for microphone access, playback and global keyboard input. Start with a foreground, single-session run before installing autostart.

## Setup

From the repository directory:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$env:GROQ_API_KEY = "<your-groq-key>"
$env:ELEVENLABS_API_KEY = "<your-elevenlabs-key>"
$env:ALGOCREED_MODE = "once"
.\.venv\Scripts\python.exe main.py
```

Check Windows microphone permissions and the selected input/output devices. ElevenLabs is the default speech backend; Vosk requires separately downloaded local models. Voice IDs can be overridden with `ELEVENLABS_VOICE_IT` and `ELEVENLABS_VOICE_EN`.

The application reads environment variables. `.env.example` is a reference list and is not automatically loaded. Variables set with `$env:` apply only to the current PowerShell process and its children. For autostart, configure the same variables in the Windows user's environment or your deployment manager; do not paste keys into tracked scripts.

## Session modes

| Mode | Behavior |
| --- | --- |
| `once` | Run one session, then exit. |
| `hotkey` | Default. Press A to start; press it again to request interruption. Override with `ALGOCREED_TRIGGER_KEY`. |
| `auto` | Start another session after the previous cycle finishes. |

Language selection supports Italian and English. Set `ALGOCREED_SKIP_LANG_SELECTION=1` and `ALGOCREED_DEFAULT_LANG=it` or `en` for a fixed language.

## Supervised launch

```powershell
$env:ALGOCREED_MODE = "hotkey"
.\run_robust.bat
```

`run_robust.ps1` prefers `.venv\Scripts\python.exe`, captures process output in `logs/`, and restarts failed processes with backoff. A single-instance mutex prevents duplicate watchdogs. `ensure_watchdog.ps1` also checks the application's heartbeat and can recover stalled processes. A successful `once` run ends the watchdog; persistent modes are restarted after exit.

## Optional autostart

After a successful foreground deployment test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_autostart.ps1
```

This installs a user Startup shortcut and interactive scheduled tasks (at logon and every minute), and starts the runtime immediately. The tasks run with limited privileges. It requires a logged-in desktop session. Use only one checkout per machine: task and mutex names are shared.

Remove the Startup shortcut and scheduled tasks with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install_autostart.ps1 -Remove
```

Removal prevents future automatic launches; it does not terminate an already running app or watchdog. Stop those processes separately when taking the installation offline. `-SkipScheduledTask` installs/removes only the Startup shortcut and does not start the runtime immediately.

## Optional archive integration

Publishing is off by default. Enable it only after an archive operator provides an HTTPS ingest endpoint and token:

```powershell
$env:ALGOCREED_PUBLISH_ENABLED = "1"
$env:ALGOCREED_INGEST_URL = "https://your-archive.example/ingest.php"
$env:ALGOCREED_INGEST_TOKEN = "<your-ingest-token>"
```

The HTTP contract is a JSON POST containing `confession`, `reply`, `processed`, `lang` and `ts`, authenticated with `X-Ingest-Token`. This public client fills both confession fields with processed text and separately processes the response. The website/backend is not part of this repository. Do not send test traffic to the artist's live archive.

Prepared entries are saved atomically in the ignored `pending_publish.jsonl` before transmission, removed after acknowledgement and retried on startup if still pending. Retry preserves the prepared text without another model call. An uncertain delivery can produce duplicates: the receiver has no idempotency contract. Failed text preparation drops the entry, with no raw fallback. Legacy unprepared queue entries are removed before preparation and may be dropped on interruption; only prepared entries have durable retry. Model-based anonymization can miss identifying details: treat pending entries as potentially sensitive and restrict local access. See the README for cloud-provider data flow and deployment limits.

## Diagnostics

- `confessional.log`: runtime state and errors.
- `logs/watchdog.log`: supervised process exits and restarts.
- `logs/guardian.log`: heartbeat recovery.
- `logs/runtime_heartbeat.json`: current lifecycle state and progress timestamps.

Logs and queues are local operational data and are excluded from Git. If provider requests fail, check credentials, model availability and network access. For a model without reasoning parameters, set `ALGOCREED_GROQ_REASONING_EFFORT` and `ALGOCREED_GROQ_REASONING_FORMAT` to empty values in your deployment environment.
