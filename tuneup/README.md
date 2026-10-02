# PC Tune-Up Scripts

Windows tuning for SETHS-PC (gaming desktop + Emby media server). Replaces the
old IObit utilities with native Windows tools.

| Script | What it does |
|---|---|
| `tuneup-gaming-media.ps1` | **Gaming + Media Server Tune-Up v3.** The big one: high-performance power plan, never-sleep server mode, Game Mode, GPU scheduling, Defender exclusions for media folders + Emby (Defender stays ON), P2P off. Logs to Desktop `tuneup-log.txt`. |
| `savant-check.ps1` | **Watchdog.** Verifies the tune-up settings are still in place (power plan, never-sleep, hibernate, Game Mode, GPU scheduling, Defender exclusions) and self-heals drift. Runs at logon + daily. |
| `savant-tweaks.ps1` | Native replacements for the last 4 IObit apps (junk cleanup, drive optimization, app updates via Winget, uninstaller helpers). Logs to Desktop `savant-tweaks-log.txt`. |
| `uninstall-iobit.ps1` | Removes all IObit apps (Advanced SystemCare, Driver Booster, Smart Defrag, Uninstaller, Software Updater) and their leftovers — scheduled tasks, services, driver registrations. Self-elevates. Run `replace-iobit.ps1` first. |
| `replace-iobit.ps1` | Puts the native replacements in place before IObit is removed: Storage Sense junk cleanup, "Muse Weekly App Updates" (Sundays 3 AM via Winget), weekly drive optimization. Self-elevates. |
| `app-inventory.ps1` | Scans everything installed on the PC (classic registry programs + Microsoft Store apps) and saves to Desktop `app-inventory.txt`. Share that file with Kavi for review. |

## Notes
- Most of these self-elevate (re-launch as admin with a UAC prompt).
- IObit removal was Seth-approved; the native takeovers run silently on schedule.
