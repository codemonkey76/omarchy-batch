# Batch

Run a script of your own over every file in a folder, one at a time, from a
panel in the Omarchy bar.

Pick an input folder, an output folder and a script. The plugin walks the input
folder, hands each file to the script, and reports progress in the bar. A batch
runs detached in its own session, so it keeps going across shell restarts,
plugin reloads and logouts.

The plugin knows nothing about what it is processing. Transcoding video,
developing raw photos, converting documents, resampling audio, running OCR —
whatever the script does is what the batch does.

## Install

```bash
omarchy plugin add https://github.com/codemonkey76/omarchy-batch --enable
```

Then place it on the bar with `omarchy plugin enable io.github.codemonkey76.batch right`,
or from **Settings → Bar**.

## Remove

```bash
omarchy plugin remove io.github.codemonkey76.batch
```

That unloads the widget and removes the plugin. Your scripts and the plugin's
state are left in place, since the scripts are yours and the state holds the
log of the last run. To remove those too:

```bash
rm -rf ~/.config/omarchy/batch ~/.local/state/omarchy-batch
```

A batch that is running when the plugin is removed keeps running to the end,
by design — cancel it first if that is not what you want.

## Dependencies

Nothing to install beyond Omarchy itself:

- **Python 3**, standard library only, at `/usr/bin/python3` — part of every
  Omarchy install
- **`omarchy-file-select`**, which ships with Omarchy, for the folder and script
  choosers
- **`xdg-open`** for the open-folder and open-log buttons — the panel says so
  if it is missing
- **`notify-send`**, optionally, for the finished notification — without it
  the batch simply finishes without one

Both are present on a standard Omarchy install.

The scripts you run bring their own dependencies. A script that calls `ffmpeg`
needs `ffmpeg` installed; the plugin itself does not.

## The script contract

A script is called **once per file**, with two arguments:

```
script <input path> <output path>
```

That is the whole interface. The plugin decides which files are in scope, where
the output goes, what to do about failures and when to stop; the script only
has to turn one file into another.

The output path mirrors the input folder's structure, so `raw/day2/IMG01.CR3`
becomes `<output>/raw/day2/IMG01.CR3`. Subfolders are created as needed. A
script is free to ignore the name it is handed and write something else — see
the note on skip-existing below.

Each script also gets these in its environment:

| Variable | Meaning |
|---|---|
| `BATCH_INPUT_DIR` | the chosen input folder |
| `BATCH_OUTPUT_DIR` | the chosen output folder |
| `BATCH_RELATIVE` | this file's path relative to the input folder |
| `BATCH_INDEX` | 1-based position in this run |
| `BATCH_TOTAL` | how many files this run found |

Scripts run with a **fixed `PATH` of `/usr/local/bin:/usr/bin:/bin`** and a
closed environment — the session variables and the ones above, nothing else
inherited from the shell. If a script needs a tool from `~/.local/bin` or a
version manager, call it by absolute path.

Anything a script writes to stdout or stderr goes to the log, capped at 256 KiB
per file.

### A script looks like this

```bash
#!/usr/bin/bash
set -euo pipefail

in=$1
out=$2

/usr/bin/ffmpeg -nostdin -loglevel warning -i "$in" -c:v libx265 -crf 24 -y "$out"
```

Exit non-zero and the file is recorded as failed and the batch moves on.

## Scripts folder

The dropdown lists what is in `~/.config/omarchy/batch/scripts` (change it in
the widget's settings). The folder is created empty — no scripts ship with the
plugin. A script has to be executable (`chmod +x`); the panel says so rather
than failing halfway through a batch. **Browse…** at the bottom of the dropdown
picks a script from anywhere.

## Which files get picked up

Every file in the folder, recursively, unless the **Only these extensions**
setting narrows it — space-separated, e.g. `mp4 mov mkv` or `cr3 nef`.

Hidden files and folders are always skipped, whatever the filter says, so a
batch over "everything" will not walk into `.git` or hand a script someone's
`.DS_Store`.

## Behaviour worth knowing

**Skip files already in output** compares the output file against its input and
skips it when the output is non-empty and no older. It matches on the exact
output path, so a script that writes a *different name* than the one it was
handed (changing `.mp4` to `.mkv`, say) produces a file the plugin is not
looking for, and those will be processed again on every run. Either keep the
name, or turn the toggle off.

**A cancelled or failed run has its output deleted**, as long as this run is
what created it. A truncated file left in place is worse than nothing: the next
run's skip-existing check would treat it as finished.

**Cancel stops the whole job**, not just the script — anything it spawned is in
the same process group and is signalled with it.

**One file at a time.** Most things worth batching already saturate the
machine, and a queue that stays predictable is easier to reason about than one
that finishes in a different order every time.

**A file that takes longer than the per-file timeout** (6 hours by default) is
abandoned and counted as failed, and the batch moves on to the next one.

## Settings

| Setting | Default | |
|---|---|---|
| Only these extensions | *(empty)* | space-separated list; empty means every file |
| Scripts folder | `~/.config/omarchy/batch/scripts` | where the dropdown looks |
| Per-file timeout | 360 min | when to give up on a single file |
| Refresh interval | 30s | how often the bar checks for a batch it did not start. A running batch is polled every second regardless. |
| Notify when finished | on | desktop notification with the counts |

## Keyboard

With the panel open: `s` start, `c` cancel, `o` open the output folder,
`l` open the log, `r` rescan, `Esc` close.

## From a terminal

The panel is a front end for a helper that works on its own:

```bash
~/.config/omarchy/plugins/io.github.codemonkey76.batch/omarchy-batch --help

omarchy-batch set input ~/Pictures/raw
omarchy-batch set output ~/Pictures/developed
omarchy-batch set script ~/.config/omarchy/batch/scripts/develop
omarchy-batch set extensions "cr3 nef"
omarchy-batch scan          # what would run
omarchy-batch start         # detached; the bar picks it up
omarchy-batch status        # one line of JSON
omarchy-batch log
```

State and logs live in `~/.local/state/omarchy-batch/`.

## Notes for review

- **No program is resolved through `PATH`.** The widget names
  `/usr/bin/python3` outright and the helper resolves every tool it runs
  (`notify-send`, `xdg-open`, `omarchy-file-select`) against a fixed set of
  system directories, checking that each is a regular file, root-owned, not
  writable by anyone else, and executable. The only exception is the
  user-chosen script, which is the point of the plugin and is run by absolute
  path.
- **Children get a closed environment** — `clearEnvironment` on the QML side, an
  explicit `env=` on the Python side, both built from a named allowlist plus a
  fixed `PATH`.
- **Output is streamed under a byte ceiling and an absolute deadline**, never
  buffered wholesale; the QML side reads one line of JSON at a time and drops
  anything implausibly long.
- **Every child is spawned into its own session** and signalled as a process
  group, `SIGTERM` then `SIGKILL` after a grace period, from a registry reaped
  on exit and on `SIGTERM`/`SIGINT`/`SIGHUP`.
- **The plugin's own state files** are opened one path component at a time from
  `/` with `O_NOFOLLOW`, written to a temporary file and replaced by rename.
- **File names and script output are treated as outside data**: control
  characters stripped and length capped before they reach the panel.

## License

MIT
