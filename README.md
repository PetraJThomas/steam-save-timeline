# steam-save-timeline

A git-backed timeline for your Steam Cloud saves. Every sync becomes a commit.
Any bad sync, whether a corrupt save got uploaded or you picked the wrong side
of the conflict dialog, becomes a two-minute rollback instead of a permanent
loss.

And because it is git underneath, you also get something Steam has never
offered: **save branches**. Fork a playthrough, try the risky build, then
either keep it or walk it back.

---

## Why

A game crashed mid-session and uploaded a **reset save** to Steam Cloud.
Choosing "remote" in the sync-conflict dialog then overwrote the good local
copy. Steam Cloud keeps **no version history**: one slot per file, last write
wins, and Steam Support cannot restore an overwritten cloud save. The save only
survived because an old disk image happened to contain a copy.

Luck shouldn't be load-bearing. Sync is not backup. This makes the backup.

## Quick start

Requires Windows and `git`. If you don't have git, setup offers to install it
for you. Everything else ships with Windows.

```powershell
powershell -ExecutionPolicy Bypass -File steam_save_setup.ps1
```

The setup window checks what you have, tells you what it found in your Steam
library, mirrors every game, and offers to **start with Windows** so capture
keeps happening on its own. It can also keep a second copy somewhere off this
drive, either in a folder such as an external drive or OneDrive, or in a free
private online backup it creates for you.

Nothing flashes a console window at you: the shortcuts and the log-on task go
through `run-hidden.vbs`, because `powershell -WindowStyle Hidden` still paints
a black box for a frame before hiding it.

It is safe to re-run at any time. Everything it does is idempotent, and on an
existing install it reports the current state and repairs whatever is missing.

That's it. From then on, every sync Steam performs becomes a point you can go
back to.

---

## How it works

### The trigger

Steam's client maintains a sync ledger per game at
`userdata\<userid>\<appid>\remotecache.vdf`. It is rewritten after **every**
cloud sync, uploads and downloads alike, with per-file SHAs, sizes and
timestamps.

Valve built version-control plumbing and pointed it at a single mutable slot.
This project adds the part that was missing: memory. A `FileSystemWatcher` on
that ledger is the tripwire, because a ledger change is exactly when cloud data
moved, and therefore exactly when a save can be destroyed.

> Older Steam clients wrote `remotecache.vcf`. Current ones write `.vdf`. The
> watcher matches `remotecache.v*` for that reason.

### What gets captured

The ledger doesn't just list files. Each entry carries a **root**, saying which
directory the path is relative to:

```
"Kayak_VR/Saved/SaveGames/main.sav"        root 3   ->  %LOCALAPPDATA%
"Defunct_x86_Data/Saves/mainLevels.sav"    root 1   ->  the game's install dir
"SEGA Mega Drive Classics/.../Local.ach"   root 2   ->  Documents
```

Root 0 is Steam's own `remote\` folder. Everything else lives out in the OS. On
a typical library that is **around half the games**, including plenty whose
saves sit in AppData. Those are mirrored too, and only the exact paths the
ledger names are ever read.

Verified root codes: `0 remote`, `1 gameinstall`, `2 documents`,
`3 localappdata`, `4 appdata`, `12 locallow`. A code outside that table gets
*probed*: try the usual save locations, keep the one where the file actually
is. So an unrecognised root degrades to "found it anyway, here's where" rather
than being silently skipped. Run `steam_save_roots.ps1 -Report` for a per-game
audit of what resolved where.

### How it's stored

**Every branch holds exactly one game.** That single rule is what makes save
branches work. Git branches are repo-wide but a save timeline is per-game, so a
shared branch would mean forking one game's history rolled back every other
game's mirror.

```
game/<name>-<appid>/main     that game's canonical timeline
game/<name>-<appid>/daily    its daily snapshots
game/<name>-<appid>/<slug>   a save branch, meaning a divergent playthrough
master                       repo metadata only
```

So `git branch` reads as `game/kayak-vr-mirage-1683340/main`, and sorts
alphabetically by game. The name is there to be read; the **appid is what code
matches on**, because Valve renames games and a ref cannot hold the colons,
slashes and trademark signs that game titles use. A game renamed later keeps
the branch it already has rather than churning.

A game's history is therefore just `git log game/<name>-<appid>/main`. Inside a
timeline:

```
<appid>/remote/...            files Steam keeps in its own remote\ folder
<appid>/roots/<root>/...      saves that live elsewhere on disk
<appid>/roots.json            which real directory each root resolved to
<appid>/remotecache.vdf       Steam's own ledger for that sync
```

Snapshots wipe and re-copy, so a **deleted** save shows up in git as a deletion
rather than lingering forever.

### Two kinds of commit

- **SYNC** means Steam actually moved data. Event-driven, lands on the game's
  active timeline.
- **SNAPSHOT** means a sweep found this on disk at that moment. Runs at startup
  and every 24 hours onto `game/<name>-<appid>/daily`.

Keeping them on separate timelines keeps both meanings honest, and the daily
sweep is your floor of coverage: at worst you lose a day, even if Steam never
syncs. The daily timeline is an archive and is never the timeline you are
*playing*, so restoring from it lands on whichever one you are.

---

## Using it

### Restoring a save

1. Open the Timeline Browser, pick the game, pick the point. Opening a point
   lists exactly what it holds: every file, its size, and when it was last
   written. That is how you spot the bad save, because the one that dropped
   to 2 KB is the reset.
2. It shows you **every directory it is about to overwrite** before touching
   anything. A restore can write into AppData, Documents or a game's install
   folder, and you should see that first.
3. Close Steam when prompted. The browser offers to do it gracefully.
4. Start Steam and launch the game. If Steam shows a sync conflict, choose
   **LOCAL**, and your restored save uploads over the bad cloud copy.
5. The watcher records that upload too, so even the recovery is in the timeline.

Per-file restores work from the command line. Steam identifies a game only by
its App ID, so start from the name:

```powershell
git branch --list "*kayak*"          # -> game/kayak-vr-mirage-1683340/main
git log game/kayak-vr-mirage-1683340/main
git checkout <commit> -- 1683340/remote/<file>
```

`GAMES.md` at the root of the mirror is the same lookup as a table, written on
every sweep, so a clone of your second copy tells you which game each numbered
folder is without needing this tool or an internet search.

### Save branches

| Action | What it does |
| --- | --- |
| **Branch / Diverge Save** | Start a new timeline at the selected point and make it active. New syncs go there, and `main` is left exactly as it was. |
| **Play this one** | Make another timeline active and load its latest save into Steam. |
| **Make canonical** | Copy a save branch's current state onto `main` as a new commit, then go back to playing `main`. |
| **Restore** | Load any point from any timeline. The restore is committed on top of whichever timeline is active. |

The commit where a save branch left `main` is tagged **DIVERGED HERE** in its
timeline, so "roll back to before I ever diverged" is one Restore on that row.

**Make canonical is a roll-forward, not a merge or a reset.** `main` keeps its
entire history and gains one commit whose content is the branch's. The save
branch survives the operation, in case it turns out to have been the better run
after all.

---

## Safety model

- **Roll-forward only.** History is append-only. A bad sync is just a commit, a
  restore is committed *on top*, and the bad state stays in history forever in
  case you ever want it back. Nothing is rewound, rebased or rewritten, which
  means a *wrong restore* is itself recoverable.
- **The watcher never writes into Steam's folders.** It observes and records:
  read-only toward Steam, append-only toward history.
- The only thing that touches Steam's files is an explicit restore, gated
  behind a Steam-is-closed check and a dialog listing every destination.
- Restores **overwrite, never delete**, because some destinations are game
  install directories where only the ledger-named files belong to us.
- **Saves are byte-exact.** The mirror sets `core.autocrlf false` and ships a
  `.gitattributes` of `* -text`. Without this, the usual global
  `core.autocrlf=true` would rewrite every LF to CRLF on checkout and hand back
  a save that is *not* the file Steam uploaded. Both are set, because repo
  config doesn't survive a clone.
- **Nothing is installed behind your back.** Setup can fetch git for you, but
  only from its own button and its own confirmation.
- The mirror is a plain git repo of plain files. No lock-in: everything is
  recoverable with git alone, without these scripts.

---

## Files

| File | Role |
| --- | --- |
| `steam_save_setup.ps1` | First-run setup. Checks, mirrors, arranges log-on start. |
| `steam_save_watcher.ps1` | The daemon. Watches ledgers, sweeps daily. `-Once` for a single sweep. |
| `steam_save_capture.ps1` | Taking a snapshot, shared by the watcher and setup. |
| `steam_save_timelines.ps1` | Save branches: per-game branches, forks, canonicalising. |
| `steam_save_roots.ps1` | Resolving Steam's root codes to real paths. `-Report` audits them. |
| `steam_save_restore_gui.ps1` | The Timeline Browser: history, save branches, restore. |
| `steam_save_theme.ps1` | One dark theme, shared by both windows. |
| `steam_save_settings.ps1` | Loads `settings.json`: mirror path, debounce, daily interval, task name. |
| SteamSaveTimeline.ahk | Optional tray app and boot hook. |
| un-hidden.vbs | Launches a script with no console window at all. Used by the shortcuts and the log-on task. |

Timeline commits are built with a throwaway git index (`read-tree`, then
`add -A -- <appid>`, `write-tree`, `commit-tree`, `update-ref`), so a branch is
extended **without ever being checked out** and without disturbing any other
game or `HEAD`. One consequence is worth knowing: the mirror's working tree is
a staging area, not a meaningful checkout. `git status` there is noise, so read
history with `git log game/<name>-<appid>/main` instead.

### The optional tray app

`SteamSaveTimeline.ahk` is a passive boot hook. It starts the watcher hidden at
log on and keeps a tray icon offering *Open Timeline Browser*, *Snapshot
everything now*, *Restart capture*, *Start with Windows* and *Exit*.

**You do not need AutoHotkey to run it.** A compiled exe bundles the AHK v2
runtime. AHK is only needed to rebuild it, and setup can install it and do the
build for you:

```
"C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in SteamSaveTimeline.ahk ^
  /out SteamSaveTimeline.exe /icon SteamSaveTimeline.ico ^
  /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

Keep the exe beside the `.ps1` files, since it finds them through its own
directory. It binds **no hotkeys** by design, so it cannot fight an existing
hotkey host. Setup offers Task Scheduler instead if you would rather have no
tray icon, and the scripts work perfectly well with neither.

---

## The second copy

It is **not** a folder copy of your saves. Setup creates a bare git repository
at `<folder>\steam-save-history.git` and pushes into it, so what lands in the
folder is a few packed files rather than thousands of loose save files. On a
29-game library that is about 490 KB in 36 files. You get it back with
`git clone`, and the files come out byte for byte.

That matters most for a synced folder. OneDrive syncing a handful of packed
files is cheap and safe; OneDrive syncing thousands of individual save files
would be slow and would invent conflict copies of them.

Reconciliation is continuous: every snapshot pushes the branch it just wrote,
and repo metadata is pushed whenever it changes. Setup shows whether the second
copy is actually current, because an unplugged drive or a paused sync otherwise
falls behind silently.

**One thing to avoid:** do not point a second PC at the same synced folder. Two
machines writing to one synced copy is what produces conflicted refs, and that
is the way to corrupt it. Give each machine its own destination.

## Accessibility

The interface is audited against **WCAG 2.2 AA**, not by eye. `contrast-check.ps1`
walks an inventory of every piece of UI copy with its real size and weight and
checks it against 1.4.3 (4.5:1 normal text, 3:1 large) and 1.4.11 (3:1 for
meaningful icons and for the boundaries of interactive components). All 77
checks pass. Static card outlines are recorded as decorative and reported as
out of scope rather than being quietly left out of the list.

Icons come from the system icon font (Segoe Fluent Icons, falling back to Segoe
MDL2 Assets), so there is nothing to install and no missing-glyph boxes. The app
icon is pulled live from `imageres.dll` for the same reason.

Inside the mirror, each game folder carries a `desktop.ini` so Explorer shows
"Kayak VR: Mirage (1683340)" while the folder is still named by App ID, which is
what every commit references. Those files are gitignored: Explorer only honours
them when the folder itself is marked read-only, and git stores no file
attributes, so a cloned copy would be inert anyway.

## Configuration

`settings.json` sits beside the scripts and is created with defaults the first
time anything runs. Values may use environment variables.

```json
{
  "mirrorDir": "%USERPROFILE%\\steam-save-history",
  "debounceSeconds": 15,
  "dailySnapshotHours": 24,
  "taskName": "Steam Save Timeline"
}
```

It is gitignored, so pulling an update never fights it, and a malformed file
falls back to defaults with a warning rather than stopping capture.

It holds **configuration only**. Whether the scheduled task exists, whether a
startup shortcut is there, which timeline is active, where the second copy
points: all of that is read from the thing itself, so a settings file can never
disagree with reality.

## Known limitations

- **Timeline density follows Steam's cadence.** The PC client syncs a game at
  client login and game launch, not continuously. The daily sweep covers the
  gap. A scheduled daily Steam restart would tighten it further for saves
  uploaded from other devices.
- **Uninstalled games with `gameinstall` saves** can't be resolved, because the
  install path comes from `appmanifest_<appid>.acf`, which disappears with the
  game. Reported as missing rather than guessed at.
- **No GUI for deleting a save branch** yet. Use `git branch -D
  game/<name>-<appid>/<slug>` by hand, and drop the entry from `timelines.json` if it
  was the active one.
- **Windows only.** The ledger-watching approach ports to Linux and the Steam
  Deck trivially.
- Only files Steam actually syncs are captured. If a game keeps part of its
  state outside Steam Cloud, that part is not in the timeline.

## License

MIT. Fork it all you want. See [LICENSE](LICENSE).
