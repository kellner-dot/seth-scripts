# Misc Scripts

One-off and cross-cutting utilities that don't fit the other folders.

| Script | What it does |
|---|---|
| `health-check.ps1` | **Kavi-independent system health check** for SETHS-PC. Covers RVG agent, TeraBox mount, Emby, Tailscale, scheduled tasks, and more. Output: GREEN/RED per system, summary at the end, exit 0 = all green. Run: `powershell -NoProfile -ExecutionPolicy Bypass -File health-check.ps1`. See `CONTINUITY.md` (in the rvg repo docs) for what to do about any RED. |
| `fix-tailscale.ps1` | Gets SETHS-PC back on the tailnet: ensures the Tailscale service is Automatic and running, re-authenticates if needed, reinstalls silently if the install is broken/missing. Logs to Desktop `tailscale-fix-log.txt`. Self-elevates. |
| `install-meshcentral.ps1` | **Historical / not used.** MeshCentral remote-access installer, researched as an RVG alternative. Seth dropped it ("no") — Chrome Remote Desktop is his own answer, RVG is the agent path. Kept for reference. |
