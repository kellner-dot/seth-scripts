# Seth's Script Library

One organized home for the PowerShell scripts scattered across the PC and
workspace. Everything here runs on SETHS-PC (Windows 11) unless noted.

**Rules:** no secrets in this repo — no tokens, API keys, passwords, or cookies.
Credentials live in the DPAPI vault on the PC (`C:\Users\sethr\rvd\MuseCredStore.psm1`)
and in Seth's Drive backup files, never in scripts.

## Index

### `rvg/` — Remote desktop agent
| Script | Purpose |
|---|---|
| `rvg-watchdog.ps1` | 2-min watchdog: keeps the RVG agent alive, restarts on failure |
| `Install-RVG.ps1` | One-time setup: GitHub PAT (SecureString) → DPAPI, update task |
| `Update-RVG.ps1` | Self-update module: pulls latest agent from private repo |
| `install-rvg15.ps1` | *(historical)* RVG 1.5 one-shot upgrade installer |
| `rvg_update_check.ps1` | *(historical)* Daily GitHub release checker |

### `kaviguard/` — Malware watchdog
| Script | Purpose |
|---|---|
| `KaviGuard-1.4.3.ps1` | Current engine build; `-TuneUp` runs the Tune-up v3 suite |
| `KaviGuard-1.4.2.ps1` | Previous build (currently running on PC) — rollback copy |
| `KaviGuard-Gui.ps1` | GUI front-end |
| `KaviGuard-Mailbox.ps1` | Mailbox poller module |
| `Install-KaviGuard.ps1` | Installs KaviGuard scheduled task |
| `Install-MailboxPoller.ps1` | Installs the mailbox poller |
| `Build-KaviGuardLauncher.ps1` | Builds the C# launcher |
| `Show-Status.ps1` | Quick status readout |

### `terabox/` — Cloud storage (Alist + rclone → T:)
| Script | Purpose |
|---|---|
| `install-terabox-stack.ps1` | One-paste installer: WinFsp + rclone + Alist, T: mount, tasks |
| `migrate-movies.ps1` | Copy-only migration with verification (never deletes) |
| `mount-watchdog.ps1` | 5-min mount health check (v1) |
| `mount-watchdog-v2.ps1` | + copy-job stall/error detection, phone push (v2) |
| `mount-watchdog-v3.ps1` | + Movies migration monitoring (v3, current) |
| `terabox-status.ps1` | Dashboard backend: rclone log → JSON progress |

### `emby/` — Media server
| Script | Purpose |
|---|---|
| `ubu-bulk-add.ps1` | Bulk-add missing FastUbu films (.strm + .nfo) to the UbuWeb library |

### `tuneup/` — PC optimization
| Script | Purpose |
|---|---|
| `tuneup-gaming-media.ps1` | Gaming + Media Server Tune-Up v3 (power, Game Mode, Defender exclusions) |
| `savant-check.ps1` | Watchdog: verifies tune-up settings, self-heals drift |
| `savant-tweaks.ps1` | Native replacements for IObit apps |
| `uninstall-iobit.ps1` | Removes all IObit apps + leftovers |
| `replace-iobit.ps1` | Installs native replacements before IObit removal |
| `app-inventory.ps1` | Full installed-app scan → Desktop `app-inventory.txt` |

### `misc/` — Utilities
| Script | Purpose |
|---|---|
| `health-check.ps1` | Kavi-independent system health check (GREEN/RED per system) |
| `fix-tailscale.ps1` | Repairs Tailscale service / reinstalls if broken |
| `install-meshcentral.ps1` | *(historical)* MeshCentral installer — dropped per Seth |

## Sources
Scripts were gathered from `~/workspace/` (rvg, kaviguard, terabox-dashboard,
continuity, kavi2/kavi4 exports, eyi-export). Duplicates deduped by hash.
Single-use data fetchers (e.g. Flix/Emby playlist builders) were intentionally
left out — this is the utility library, not the one-off shelf.

30 scripts, 6 folders. Last organized: 2026-09-30.
