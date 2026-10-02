# Emby Scripts

Helpers for Seth's Emby Server 4.10.0.40 (Premiere) on SETHS-PC, port 8096.

| Script | What it does |
|---|---|
| `ubu-bulk-add.ps1` | Bulk-adds missing FastUbu films to the Emby UbuWeb library. Reads `C:\Users\sethr\rvd\ubu-missing.json`, creates a `.strm` + `.nfo` per film, tracks progress in `ubu-bulk-add-progress.txt`. Usage: `.\ubu-bulk-add.ps1 -BatchSize 200 -BatchNumber 0` (0-indexed batches). |

## Notes
- The Emby API key is never stored in scripts — use the DPAPI vault on the PC
  (`C:\Users\sethr\rvd\MuseCredStore.psm1`) or the `fast.sh` helpers.
- Chelsea's login stays clean: Movies, TV shows, Collections only. Adult VOD and
  adult channels are blocked on her account — never add them.
