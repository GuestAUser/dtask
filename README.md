<p align="center">
  <img src="assets/wordmark.png" alt="dtask" width="480">
</p>

# dtask

A keyboard- and mouse-driven task manager for the terminal, written in D.
Organize tasks by priority and due date, search notes, and drag tasks onto a
schedule. Data stays in a local JSON file; no account, service, or runtime
packages are required.

## Installation

Requires [LDC](https://github.com/ldc-developers/ldc/releases) 1.43 or newer
and GNU Make.

```sh
git clone https://github.com/GuestAUser/dtask.git
cd dtask
./install.sh
dtask
```

The installer builds dtask and installs it to `~/.local/bin` without sudo.
If needed, it prints the command to add that directory to `PATH`; it does
not modify shell profiles. Use `./install.sh --prefix PATH` to choose a
destination or `DC=/path/to/ldc2 ./install.sh` to select a compiler.

To run without installing:

```sh
make
./bin/dtask
```

[DUB](https://dub.pm/) is also supported: `dub build --compiler=ldc2`.

Targets Linux (including WSL), macOS, and FreeBSD. CI runs on Linux and
macOS. The interface requires a UTF-8 locale and an ANSI/VT-compatible
terminal of at least **48 columns x 20 rows**; truecolor is recommended.
Native Windows consoles are not supported.

## Usage

Press `?` for the full shortcut reference. Help supports arrow keys,
Page Up/Down, Home/End, and mouse scrolling.

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | Select a task |
| `n` | New task |
| `e`, Enter | Edit selected task |
| `v` | Read full title and notes |
| Space | Complete or reopen |
| `p` | Cycle priority |
| `d` | Delete after confirmation |
| `/` | Search titles and notes |
| `1` / `2` / `3` / `4` | Open / Today / All / Done |
| Esc | Cancel or clear search |
| `m` / `r` | Toggle motion / reload theme |
| `q`, Ctrl-C | Quit |

Click a task to select it or its checkbox to complete it. Drag onto
**Today**, **Tomorrow**, **Weekend**, **Next week**, or **No date** to
schedule; **Calendar** selects a specific day. Esc, resizing, or dropping
outside a target cancels the drag.

In the editor, Tab moves between fields. **Edit description** opens a
multiline draft. **Back** keeps the draft, **Save** applies it, and
**Cancel** discards it. Pasted text never runs shortcuts.

Dates accept `YYYY-MM-DD`, `today`, `tomorrow`, `fri`, `next monday`,
`next week`, `weekend`, `+7d`, or `in 7 days`. Next week means the next
Monday; weekend means the nearest Saturday. Use `none` to remove a date.
The Today view includes overdue tasks.

Motion is brief and interruptible, pauses while editing, and stops when
idle. Set `DTASK_REDUCED_MOTION=1` to start with effects disabled.

## CLI

```sh
dtask add "Prepare the release" --priority high --due tomorrow
dtask add "Review proposal" --notes "Check the migration section"
dtask list --all --json
dtask done 1
dtask delete 1
```

`done` is idempotent. CLI deletion is immediate; the interactive interface
asks for confirmation. Use `--data PATH` for a separate workspace,
`--theme PATH` for a theme, and `--help` for all options.

## Configuration and storage

| File | Default location |
| --- | --- |
| Tasks | `~/.local/share/dtask/tasks.json` |
| Theme | `~/.config/dtask/theme.json` |

`XDG_DATA_HOME` and `XDG_CONFIG_HOME` override those base directories.
Task changes are saved atomically. Each open store holds an exclusive lock;
close the interface before using the CLI with the same file.

The default theme is Midnight. Copy [Midnight](themes/midnight.json) or
[Ember](themes/ember.json) to the theme location, or provide partial overrides:

```json
{
  "name": "Custom",
  "accent": "#C4A7E7",
  "selected": "#2A2440"
}
```

Colors use `#RRGGBB`. Press `r` to reload a loaded theme; invalid changes
leave the current palette intact. Restart to discover a newly created
default theme file.

## Development

```sh
make test
```

Tests cover the model, storage, input decoding, rendering helpers, and real
terminal interactions. Integration tests require Python 3.10 or newer and
use temporary stores. See [CONTRIBUTING.md](CONTRIBUTING.md) for build options
and code conventions.

## License

[MIT](LICENSE).
