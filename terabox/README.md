# TeraBox Scripts

TeraBox is Seth's free-tier cloud storage, mounted on the PC through
Alist/WebDAV (local port 5244) → rclone → `T:` drive. These scripts install the
stack, migrate media, and keep the mount healthy.

| Script | What it does |
|---|---|
| `install-terabox-stack.ps1` | **One-paste installer** (idempotent, safe to re-run). Installs WinFsp + rclone + Alist, links the TeraBox account, creates the rclone `tb` remote, mounts TeraBox as `T:`, and sets up auto-start scheduled tasks. |
| `migrate-movies.ps1` | Copies movies to TeraBox via the rclone `tb` remote — **never deletes anything**. Refuses OneDrive online-only placeholders. Verifies with `rclone check` + file-count/bytes match + SHA256 manifest CSV, then prints the staged deletion command for Seth to review. |
| `mount-watchdog.ps1` | **Live (v1).** Runs every 5 min via the "TeraBox Watchdog" task. Ensures `T:` is accessible; restarts the mount if not. |
| `mount-watchdog-v2.ps1` | **Live (v2).** Mount health + copy-job stall/error detection from rclone logs. Phone push via ntfy + PC toast on issues (60-min anti-spam cooldown). |
| `mount-watchdog-v3.ps1` | **Live (v3).** Everything in v2, plus monitors the Movies migration rclone processes (started by the daily "TeraBox Uploaders" task) for stalls/errors/idle. |
| `terabox-status.ps1` | Backend for the migration dashboard. Parses rclone logs and outputs migration progress as JSON (consumed by `terabox-dashboard.html`). |

## Known quirks
- Free tier: 4 GB max per file. 23 oversized movies stay local (Seth refused splitting).
- Uploads stall during peak hours (TeraBox throttles free tier). Resilient flags: `--timeout 30m --contimeout 2m --retries 10 --retries-sleep 60s --low-level-retries 20`, 2 transfers.
- Emby reports TeraBox file sizes as 0 via API — byte-verification must happen on the PC side.
- **Rule:** nothing leaves C:/D: until verified byte-identical on TeraBox AND playable in Emby from there.
