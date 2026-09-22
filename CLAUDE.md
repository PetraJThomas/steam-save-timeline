# Steam Save Timeline

Repo: `C:\PersonalProjects\steam-save-timeline`, published at
https://github.com/PetraJThomas/steam-save-timeline (public, MIT).
`C:\Users\petra\Scripts` still holds a working copy alongside unrelated
personal scripts; the repo is the source of truth, so change it there and
copy across, not the other way round. The mirror of actual save data lives
in `%USERPROFILE%\steam-save-history` and is gitignored: it must never end
up inside the source repo.

Git-backed timeline of Steam Cloud saves, so any bad sync (corrupt save
uploaded, wrong conflict choice) is recoverable. Born from a real loss: a
crash in a game running on Android uploaded a reset save, and choosing
"remote" in Steam's conflict dialog destroyed the good local copy.
Steam Cloud keeps no version history, this system is that history.

## Architecture

Windows PowerShell 5.1 compatible throughout, git on PATH. `README.md` is the
user-facing doc; this file is the working notes.

- `steam_save_setup.ps1`, first-run setup (the OOBE). Preflight checks, a
  survey of what's actually in the library, the first sweep, and optionally
  log-on start / desktop shortcut / remote. Idempotent: on an existing
  install it reports state and repairs what's missing, so it doubles as a
  diagnostic. Work runs on the UI thread with a dispatcher pump between
  games (`Sync-Ui`) rather than a runspace, simpler, and the sweep is the
  only slow part. Checks run on `ContentRendered`, not before `ShowDialog`,
  so the window paints before the library survey stalls it.

- `steam_save_capture.ps1`, taking a snapshot: `Initialize-Repo`,
  `New-Snapshot`, `Invoke-Sweep`. Lifted out of the watcher so setup runs
  the first sweep through exactly the code the daemon uses later. Progress
  goes through `Set-CaptureLogger`, so the same functions write to a console
  or into a window.

- `steam_save_theme.ps1`, the dark theme as a XAML fragment, interpolated
  into both windows. Not a ResourceDictionary file: keeping it a string
  means no extra file to ship and the two windows cannot drift apart.

- `steam_save_dialogs.ps1`, themed confirm/notice dialogs shared by both
  windows. MessageBox.Show is gone from the project: it could not show the
  restore confirmation's LIST of directories about to be overwritten, which is
  the thing worth reading slowly before saying yes.

- `contrast-check.ps1`, WCAG 2.2 AA audit of every piece of UI copy, with its
  real size and weight. Run it after ANY theme change; it exits non-zero on
  failure. Rules that bit: dark-on-accent cannot survive past about a 32%
  shade, which is why the primary button's pressed state keeps the hover fill
  and shows itself with a rim instead of going darker. Badge label colour
  follows its fill rather than being fixed dark, because the dim SNAPSHOT and
  CREATED fills failed at 3.67:1 and 2.56:1.

- Icons are the system icon font ("Segoe Fluent Icons, Segoe MDL2 Assets"), so
  nothing ships and nothing is missing on Win10 or 11. Two rules: render any new
  glyph and LOOK at it before committing, since a wrong codepoint is a silent
  blank box; and never put Latin text in an icon-font TextBlock, because the
  font has no letters and "GAMES" came out as five boxes.

- A folder second copy gets BOTH a bare repo (history) and "Your saves
  (latest)" as plain files, plus a README and a recovery script. The plain copy
  exists because the disaster case is someone on a new machine with only their
  synced folder: recovery must not require git, or knowing git. The repo alone
  failed that test. `Update-PlainCopy` refreshes one game after its push, and
  only for a filesystem destination, since an online backup is a URL.

- The "second copy" repo is a bare repo the mirror pushes to, never a file copy of
  the save folder: a synced folder then carries a few packfiles instead of
  thousands of loose saves. Reconciliation is per-push, so anything that
  commits must also push, or that part of the copy freezes. `Save-Metadata`
  pushes for exactly that reason: without it the second copy kept every save
  but froze games.json and timelines.json at day one.

- `steam_save_settings.ps1` / `settings.json`, the single source for mirror
  path, debounce, daily interval and task name. `$MirrorDir` used to be
  declared separately in three scripts; three copies of a path that must agree
  is a bug waiting to happen. Configuration ONLY: state (task installed,
  shortcut present, active timeline, remote url) is always read from the thing
  itself, so settings can never disagree with reality. Gitignored, created on
  demand, malformed file falls back to defaults rather than stopping capture.

- The app icon is pulled live from `imageres.dll` (no .ico ships). Two traps,
  both measured rather than guessed: **ExtractIconEx indexes from 0 and AHK
  from 1**, so the same picture is 142 in the theme and 143 in the .ahk; and
  much of that DLL is **overlay badges**, a small glyph in the corner of a
  32x32 canvas, which shrink to a dot in a title bar. Before using any icon,
  measure its non-transparent bounding box: anything under about 75% fill is a
  badge, not an app icon. The OneDrive cloud is also out on purpose, since this
  tool offers OneDrive as a destination and that icon would read as sync status.

- `desktop.ini` in each game folder gives Explorer a readable label while the
  folder stays named by appid. It is **gitignored deliberately**, for two
  reasons that were tested, not assumed: Explorer only honours it when the
  FOLDER carries the ReadOnly attribute, and git stores no attributes, so a
  cloned copy would be inert; and because the label contains the game name, a
  Steam rename would otherwise write a commit into that game's save timeline
  whose only change is a cosmetic file. Do not "fix" the gitignore.

- `run-hidden.vbs`, a three-line WScript shim. Everything launched from a
  shortcut or the log-on task goes through it, because
  `powershell -WindowStyle Hidden` still creates and paints a console for a
  frame before hiding it, which reads as a glitch at log-on. Verified: no
  `ConsoleWindowClass` window is created at all. Do not "simplify" a launcher
  back to plain powershell.exe.

- `SteamSaveTimeline.ahk`, optional AHK v2 tray app / boot hook. Starts the
  watcher hidden, offers the browser from the tray, and carries a
  **Start with Windows** toggle that writes/removes its own Startup shortcut,
  so the one setting anyone revisits does not require opening setup. Compiled, it needs no
  AHK installed (the exe bundles the v2 runtime); AHK is only needed to
  rebuild. **It binds no hotkeys on purpose**. Hotkeys.exe is this
  machine's single resident hotkey host and two hosts would fight. A hotkey
  for the browser belongs in Hotkeys.ahk's BINDINGS table.

- `steam_save_timelines.ps1`, save branches, dot-sourced by watcher and GUI.
  **Every branch holds exactly one game.** That one rule is what makes save
  branches work: git branches are repo-wide but a save timeline is per-game,
  so a shared branch would mean forking one game's timeline rolled back every
  other game's mirror.

      game/<name>-<appid>/main    canonical timeline, e.g.
                                  game/kayak-vr-mirage-1683340/main
      game/<name>-<appid>/daily   daily snapshots (an archive, never active)
      game/<name>-<appid>/<slug>  a save branch, a divergent playthrough
      master                      repo metadata (games.json, timelines.json)

  The name is a label; the **appid is the identity**. Never match on the slug:
  names change, and `Get-GameBranchRoot` finds a game's refs by appid
  (`game/*-<appid>/*`, plus the legacy `game/<appid>/*`) so a rename on Steam
  does not orphan anything. `Update-BranchNaming` migrates old mirrors with
  `git branch -m`, which moves refs and keeps every commit; it runs on watcher
  and setup start and is idempotent.

  Exactly one timeline per game is *active* (`timelines.json`, appid -> branch,
  absent = main); the watcher appends syncs to it. Commits are built with a
  throwaway index, `read-tree` from the target branch, `add -A -- <appid>`,
  `write-tree`, `commit-tree`, `update-ref`, so a branch is extended without
  ever being checked out and without touching any other game or HEAD.

- `steam_save_roots.ps1`, shared resolver, dot-sourced by the other two.
  Parses Valve KeyValues (remotecache.vdf, libraryfolders.vdf,
  appmanifest_*.acf), enumerates every Steam library, and maps a cloud
  file's numeric `root` to a real directory. Verified root codes:
  0 `remote`, 1 `gameinstall`, 2 `documents`, 3 `localappdata`,
  4 `appdata`, 12 `locallow`. An unrecognised code is *probed*, try the
  usual save locations and keep the one where the file actually is, so a
  new root degrades to "found it anyway" rather than "skipped". Run it
  directly with `-Report` for a per-game audit of roots and their paths;
  that report is also how a new code gets verified before being added to
  the table.

- `steam_save_watcher.ps1`, the backend. FileSystemWatcher on
  `userdata\<uid>\<appid>\remotecache.v*` (Steam's sync ledger, rewritten
  after every upload AND download; current clients write `.vdf`, older ones
  `.vcf`). On change: 15s debounce, wipe-and-recopy into
  `%USERPROFILE%\steam-save-history\<appid>\` (so deletions show in git):
    - `remote\` copied wholesale, catches files Steam hasn't indexed yet
    - `roots\<root>\` per file, driven by the ledger, for saves that live
      outside `remote\`; only listed paths are ever read
    - `roots.json`, which real directory each root resolved to
    - the ledger itself, for Steam's sha/remotetime metadata
  Then commits to that game's *active* timeline, and pushes that branch if
  an `origin` remote exists.

  Separately it **sweeps** every game onto `game/<name>-<appid>/daily` at startup
  and every `$DailySnapshotHours` (24). The split is the point: a commit on
  a sync timeline means Steam actually moved data; a commit on a daily
  timeline means "this is what was on disk at time T". Mixing them dilutes
  both. The sweep is also the floor of coverage, at worst you lose a day,
  even if Steam never restarts, and it seeds `main` for any game that does
  not have a timeline yet, so every game has a canonical history from first
  sight. Maintains `games.json` (appid -> name, from `appmanifest_*.acf`
  across all libraries). Meant to run permanently via Task Scheduler "At log
  on".

- `steam_save_restore_gui.ps1`. The **Timeline Browser** (that is its window title and header; the setup window is the other one). WPF, dark themed, all
  styling inline in the XAML (no external theme assemblies, the zero-
  dependency rule applies to the UI too; even the scrollbars are
  retemplated, because the stock ones are light grey). Timelines are pill
  buttons rather than a combo box, so a ComboBox ControlTemplate does not
  have to be hand-rolled. Timeline rows are colour-coded by event kind:
  SYNC (blue, Steam moved data), SNAPSHOT (slate, a sweep), RESTORE
  (amber), CANONICAL (green), CREATED (grey), plus a DIVERGED HERE chip.
  Game list from games.json; a timeline picker per game, and
  one branch per game means history is just `git log game/<name>-<appid>/main`.
  Beyond Restore it offers **Branch / Diverge Save** (new save branch at the
  selected point, becomes active), **Play this one** (make another timeline
  active and load its latest save), and **Make canonical** (commit a save
  branch's current state onto main, then go back to playing main). The point
  where a save branch left main is marked DIVERGED HERE, so "roll back to
  before I diverged" is one Restore on that row.
  Restore: reads the target commit with `git ls-tree` and shows every
  destination it would overwrite *before* touching anything; warns if
  steam.exe is running and offers graceful `steam.exe -shutdown`; then
  `git checkout <hash> -- <appid>/`, commits that on top as a RESTORE
  commit *on the active timeline*, and copies `remote\` plus each
  `roots\<root>\` back to the directory that root resolves to now (falling
  back to the recorded roots.json if it cannot). Copies overwrite, never
  delete, some destinations are game install folders. User launches game
  and picks LOCAL if Steam shows a conflict.

## Design principles (do not change without asking)

- Roll-forward only. Never rebase/reset the mirror repo. A bad sync is a
  commit; a restore is another commit on top. History is append-only. This
  is why "make canonical" copies a branch's state onto main as a new commit
  instead of merging or moving main's pointer, and why the save branch
  survives the operation, in case it turns out to have been the better run.
- One game per branch, no exceptions, including the daily timelines.
- The mirror's working tree is a staging area, not a meaningful checkout:
  commits are built through a throwaway index, so `git status` there is
  noise. Read history with `git log game/<name>-<appid>/main`, not `git status`.
- Watcher observes only, it never writes into Steam's folders. Only the
  GUI's explicit restore touches Steam, and only after the Steam-running
  gate.
- Commit messages start with `[<appid>]`, fixed machine-parseable anchor.
- Saves are opaque bytes. The repo sets `core.autocrlf false` and ships a
  `.gitattributes` of `* -text`; a restored save must be byte-identical to
  what Steam uploaded.
- Root codes are only added to the table once verified on real data (an
  entry from a live ledger resolving to a file that exists). Unverified
  guesses stay out, the probe fallback covers them safely.
- Root short names (`localappdata`, `gameinstall`, ...) are an on-disk
  contract: renaming one orphans everything already committed under it.
- Zero dependencies: PS 5.1 stdlib/.NET + git.

## Open items (priority order)

1. Commit the owner's recovered save (pulled from an old PC image) as the
   known-good first entry for that game.
2. No way to delete a save branch from the GUI yet, `git branch -D
   game/<name>-<appid>/<slug>` by hand, and drop the entry from `timelines.json`
   if it was active.
3. Optional: scheduled daily Steam restart (`steam.exe -shutdown`, wait,
   relaunch with `-silent`) to force a sync checkpoint, capping the loss
   window for saves uploaded from other devices.
4. Root 1 (`gameinstall`) resolves through `appmanifest_<appid>.acf`. If
   the game is uninstalled the manifest is gone, so those saves cannot be
   mirrored or restored until it is reinstalled, the report shows them as
   missing rather than pretending otherwise.

## Context notes

- PC-side Steam only syncs a game at client login / game launch, so the
  timeline density depends on how often Steam restarts (hence item 3).
- The ledger is `remotecache.vdf` on current clients. An earlier version of
  the watcher looked for `remotecache.vcf` only and therefore never fired
  once; the filter is `remotecache.v*` for that reason. If snapshots ever
  stop appearing, check that filename first.
- git writes ordinary warnings to stderr. Under `$ErrorActionPreference =
  'Stop'` with `2>&1`, PowerShell turns those into terminating errors and
  silently aborts every snapshot. `Invoke-Git` in both scripts drops to
  'Continue' and judges git by exit code only, don't "tidy" that away.
- Mobile/Android capture was considered (Termux cron into the same repo)
  but deprioritized, owner has stepped back from PC-emulation-on-Android.
