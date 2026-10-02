# RVG Scripts

Scripts for Seth's in-house remote desktop agent (RVG) running on SETHS-PC.
RVG serves a web viewer and agent API on port 8899 (X-RVD-Token header auth).

| Script | What it does |
|---|---|
| `rvg-watchdog.ps1` | **Live.** Runs every 2 min via the "RVG watchdog" scheduled task. Ensures the RVG agent is alive and responding; on failure kills stale port-holders and restarts the "RVG agent" task. Sends PC toast on recovery. |
| `Install-RVG.ps1` | **One-time setup.** Run once on the PC as Administrator. Prompts for the GitHub fine-grained PAT (SecureString, never echoed), DPAPI-encrypts it to `$env:ProgramData\RVG\github.pat`, copies `Update-RVG.ps1` into place, and creates the "RVG update check" scheduled task. |
| `Update-RVG.ps1` | **Live.** Self-update module run by the "RVG update check" task (~6h cadence). Pulls the latest `src/rvg_agent.py` from the private `kellner-dot/rvg` repo using the DPAPI-encrypted PAT. No secrets in the file itself. |
| `install-rvg15.ps1` | **Historical.** One-shot installer for the RVG 1.5 upgrade (elevated PowerShell). Installed the v1.5 agent + viewer to `%USERPROFILE%\rvd\rvg15\`, recreated the "RVG agent" logon task, and added the daily "RVG update check" task. Superseded by the GitHub auto-deploy pipeline. |
| `rvg_update_check.ps1` | **Historical.** Daily update checker that queried the GitHub API for the latest RVG release and pulled `rvg_update_config.json`. Superseded by `Update-RVG.ps1` + the Tailscale→GitHub auto-deploy workflow. |

## Requirements
- Windows 10/11, PowerShell 5.1+
- Tailscale on the tailnet for remote API access
- The RVG token lives in `C:\Users\sethr\rvd\token.txt` (never in these scripts)
