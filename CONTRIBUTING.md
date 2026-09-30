# Contributing to dtask

dtask is a dependency-free D terminal task manager for Linux, macOS, and
FreeBSD. Production modules live in `source/`, tests in `tests/`, and sample
themes in `themes/`.

## Build and verify

```sh
make
make test
```

Set `DC=/path/to/ldc2` when LDC is not on PATH. Make and DUB treat compiler
warnings and deprecations as errors. DUB builds only the application, with no
third-party package dependencies:

```sh
dub build --compiler=ldc2 --build=release
./bin/dtask --version
```

Integration checks require Python 3.10 or newer and a POSIX pseudo-terminal.
They use temporary stores and never read or alter your own task data. The
runtime needs no Python, DUB, or third-party libraries; it uses the standard
POSIX system libraries. Native CI runs on Linux and macOS.

To keep Make outputs outside the checkout, set `BIN_DIR`:

```sh
make test BIN_DIR=/tmp/dtask-build
```

Install under `~/.local` with `make install`, or stage a system installation
without touching the host filesystem:

```sh
make install PREFIX=/usr/local DESTDIR=/tmp/dtask-install
/tmp/dtask-install/usr/local/bin/dtask --version
```

`PREFIX` is the final installation prefix; `DESTDIR` is an optional staging
root. Neither changes the executable's runtime behavior. `make clean` removes
the selected `BIN_DIR` and the local DUB cache.

To retain terminal captures for debugging, set `DTASK_EVIDENCE_DIR` to a
directory outside your checkout before running `make test`. Otherwise,
temporary captures are automatically removed after the tests finish.

## Code conventions

Use readable conditions, blank lines between logical steps, and explanatory
comment blocks around algorithms and operating-system boundaries. Explain
calendar arithmetic and ordering rules where they are implemented.
Use Ddoc blocks (`/** ... */`) for public APIs and standard block comments
(`/* ... */`) for implementation explanations and section headings.

Keep tests separate from production modules. New behavior should have a
regression test at its nearest useful boundary; terminal interactions also
need a real pseudo-terminal scenario. Synchronize tests with emitted events
or complete frames rather than fixed sleeps.

The model owns date normalization, task ordering, validated storage, and
atomic persistence. The terminal owns POSIX state and input decoding. The
theme loader owns color configuration. The UI combines these modules without
moving storage or terminal operations into layout code.

All persisted or user-provided text must pass through display-cell fitting
before being rendered. Never interpolate untrusted text into ANSI commands.
Terminal cleanup must restore cursor, mouse tracking, and input mode on both
normal exit and handled failure paths.

Preserve the JSON schema when changing the UI. Mutations must be saved
atomically, reject concurrent writers, and leave malformed files untouched.
