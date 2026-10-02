# KaviGuard Scripts

KaviGuard is Seth's malware watchdog for his PC — watches Downloads/Desktop/Temp,
runs a daily quick scan (~3 AM) and a weekly full scan (Sun ~3 AM). Repo:
`kellner-dot/kaviguard`.

| Script | What it does |
|---|---|
| `KaviGuard-1.4.3.ps1` | **Current build** (delivered to Downloads 2026-09-29). Full watchdog engine. The `-TuneUp` switch runs the Tune-up v3 suite. **Seth-side task:** run from an elevated admin PowerShell. |
| `KaviGuard-1.4.2.ps1` | **Previous build** — the version currently running on the PC. Kept for rollback. |
| `KaviGuard-Gui.ps1` | GUI front-end for KaviGuard (status window, scan controls). |
| `KaviGuard-Mailbox.ps1` | Mailbox poller module — lets KaviGuard pull log requests / commands from the shared mailbox. |
| `Install-KaviGuard.ps1` | Installs KaviGuard as a scheduled task / service on the PC. |
| `Install-MailboxPoller.ps1` | Installs the mailbox poller component. |
| `Build-KaviGuardLauncher.ps1` | Builds the C# launcher (`KaviGuardLauncher.cs`) that starts the engine. |
| `Show-Status.ps1` | Quick status readout — is KaviGuard running, when did it last scan, any detections. |

## Notes
- Engine source is a single self-contained `.ps1` per version (easy to diff).
- Never commit credentials — KaviGuard logs stay on the PC.
