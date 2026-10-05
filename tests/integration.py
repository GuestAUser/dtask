#!/usr/bin/env python3
"""Exercise the compiled CLI and real POSIX terminal without timing sleeps."""

from __future__ import annotations

import errno
from datetime import date, timedelta
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import termios
from time import monotonic
import unicodedata
from contextlib import contextmanager
from collections.abc import Iterator

class TerminalSession:
    """Own a real PTY and subscribe to complete frames before sending input."""

    def __init__(
        self, binary: str, data: Path, columns: int, rows: int,
        theme: Path | None = None, reduced_motion: bool = True,
    ) -> None:
        self.master, self.slave = pty.openpty()
        self.rows = rows
        self.columns = columns
        fcntl.ioctl(self.slave, termios.FIONREAD, struct.pack("i", 0))
        self.original = termios.tcgetattr(self.slave)
        self.pending = b""
        self.frames: list[bytes] = []
        self.latest_full = b""
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.master, selectors.EVENT_READ)
        self.resize(columns, rows)
        arguments = [binary, "--data", str(data)]
        if theme is not None:
            arguments.extend(["--theme", str(theme)])
        self.process = subprocess.Popen(
            arguments,
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env={
                **os.environ, "TERM": "xterm-256color", "LC_ALL": "C.UTF-8",
                "DTASK_REDUCED_MOTION": "1" if reduced_motion else "0",
            },
        )
        self.frame()

    def resize(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def frame(self, full: bool = True) -> bytes:
        """A full final row plus reset is the renderer's completion boundary."""
        marker = f"\x1b[{self.rows};1H".encode()

        while True:
            start = self.pending.find(marker)
            end = self.pending.find(b"\x1b[0m", start) if start >= 0 else -1

            if end >= 0:
                result = self.pending[: end + 4]
                self.pending = self.pending[end + 4 :]
                complete = all(
                    f"\x1b[{row};1H".encode() in result
                    for row in range(1, self.rows + 1)
                ) or self.columns < 48 or self.rows < 20

                if complete:
                    self.latest_full = result
                elif full:
                    continue

                self.frames.append(result)
                return result

            if not self.selector.select(timeout=5):
                raise AssertionError(
                    f"No complete {self.columns}x{self.rows} frame; "
                    f"exit={self.process.poll()}, tail={self.pending[-1000:]!r}"
                )

            try:
                chunk = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""

            if not chunk:
                raise AssertionError(f"TUI exited before a frame: {self.pending[-2000:]!r}")

            self.pending += chunk

    def send(self, value: str) -> bytes:
        os.write(self.master, value.encode())
        return self.frame()

    def type_text(self, value: str) -> None:
        for character in value:
            self.send(character)

    def cell(self, label: str, min_row: int = 1) -> tuple[int, int]:
        """Locate a visible mouse target in the latest actual rendered frame."""
        rows = re.split(rb"\x1b\[(\d+);(\d+)H", self.latest_full)
        for index in range(1, len(rows), 3):
            row = int(rows[index])
            column = int(rows[index + 1])
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", rows[index + 2]).decode()
            start = plain.find(label)
            if start >= 0 and row >= min_row:
                for character in plain[:start]:
                    if not unicodedata.combining(character):
                        column += 2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
                return column, row
        raise AssertionError(f"No visible mouse target {label!r}")

    def click(self, label: str) -> bytes:
        x, y = self.cell(label)
        self.send(f"\x1b[<0;{x};{y}M")
        return self.send(f"\x1b[<0;{x};{y}m")

    def drag(self, source: str, target: str) -> bytes:
        x, y = self.cell(source, min_row=8)
        destination_x, destination_y = self.cell(target)
        self.send(f"\x1b[<0;{x};{y}M")
        self.send(f"\x1b[<32;{destination_x};{destination_y}M")
        return self.send(f"\x1b[<0;{destination_x};{destination_y}m")

    def finish(self, key: str = "q") -> None:
        os.write(self.master, key.encode())
        assert self.process.wait(timeout=5) == 0
        self.assert_restored()

    def assert_restored(self) -> None:
        # Darwin sets PENDIN when canonical mode is restored. FIONREAD lets
        # the line discipline reprocess pending input and clear that transient
        # bit without consuming input or changing any configured attributes.
        # Compare every setting exactly after the same query used at startup.
        fcntl.ioctl(self.slave, termios.FIONREAD, struct.pack("i", 0))
        restored = termios.tcgetattr(self.slave)
        assert restored == self.original, (
            f"Terminal settings were not restored: expected={self.original!r}; actual={restored!r}"
        )

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.selector.close()
        os.close(self.master)
        os.close(self.slave)

@contextmanager
def terminal(
    binary: str, data: Path, columns: int = 120, rows: int = 32,
    theme: Path | None = None, reduced_motion: bool = True,
) -> Iterator[TerminalSession]:
    session = TerminalSession(binary, data, columns, rows, theme, reduced_motion)
    try:
        yield session
    finally:
        session.close()

def command(binary: str, data: Path, *args: str, success: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [binary, "--data", str(data), *args],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert (result.returncode == 0) == success, (args, result.returncode, result.stdout, result.stderr)
    return result

def cli_checks(binary: str, root: Path) -> None:
    data = root / "cli.json"
    command(binary, data, "add", "Ship release", "--priority", "urgent", "--due", "2030-01-02")
    command(binary, data, "add", "Review notes", "--notes", "Keep it simple")
    tasks = json.loads(command(binary, data, "list", "--json").stdout)
    assert [task["title"] for task in tasks] == ["Ship release", "Review notes"]
    assert tasks[0]["due"] == "2030-01-02"
    assert tasks[0]["priority"] == "urgent"
    release_id = str(tasks[0]["id"])

    command(binary, data, "done", release_id)
    command(binary, data, "done", release_id)
    remaining = json.loads(command(binary, data, "list", "--json").stdout)
    assert len(remaining) == 1 and remaining[0]["title"] == "Review notes"
    command(binary, data, "delete", release_id)
    assert len(json.loads(command(binary, data, "list", "--all", "--json").stdout)) == 1

    before = data.read_bytes()
    command(binary, data, "add", "Bad date", "--due", "2026-02-30", success=False)
    command(binary, data, "add", "Bad priority", "--priority", "impossible", success=False)
    command(binary, data, "done", "999999", success=False)
    command(binary, data, "--data", "", "list", success=False)
    assert data.read_bytes() == before

    corrupt = root / "corrupt.json"
    corrupt.write_text("{invalid", encoding="utf-8")
    command(binary, corrupt, "add", "Must not overwrite", success=False)
    assert corrupt.read_text(encoding="utf-8") == "{invalid"
    command(binary, data, success=False)  # Pipes are not interactive terminals.
    print("PASS: CLI persistence, sorting, completion, deletion, invalid input, corruption and non-TTY")

def cli_option_checks(binary: str, root: Path) -> None:
    data = root / "literal-options.json"
    options = ("--help", "-h", "--version")

    for option in options:
        command(binary, data, "add", "Literal option value", "--notes", option)

    tasks = json.loads(command(binary, data, "list", "--json").stdout)
    assert tuple(task["notes"] for task in tasks) == options

    environment = {
        key: value for key, value in os.environ.items()
        if key not in ("HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME")
    }
    unused = root / "unused.json"

    for option in options:
        result = subprocess.run(
            [binary, "--data", str(unused), option],
            env=environment, capture_output=True, text=True, timeout=10, check=False,
        )
        assert result.returncode == 0, (option, result.stderr)
        assert result.stdout and not result.stderr

    assert not unused.exists() and not unused.with_suffix(".json.lock").exists()

    theme = root / "explicit-theme.json"
    theme.write_text("{}", encoding="utf-8")
    result = subprocess.run(
        [binary, "--data", str(data), "--theme", str(theme), "list", "--json"],
        env=environment, capture_output=True, text=True, timeout=10, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == tasks
    print("PASS: literal option values, independent help/version and explicit paths without HOME")

def tui_checks(binary: str, root: Path, evidence: Path) -> None:
    data = root / "tui.json"

    with terminal(binary, data) as session:
        evidence.joinpath("empty.ansi").write_bytes(session.frames[-1])
        session.send("n")
        session.type_text("Plan release")
        session.send("\t")
        session.send("\x15")
        session.type_text("high")
        session.send("\t")
        session.type_text("2030-12-31")
        session.send("\t")
        session.type_text("Read the rollout checklist")
        evidence.joinpath("form.ansi").write_bytes(session.frames[-1])
        session.click("[Save]")
        evidence.joinpath("workspace.ansi").write_bytes(session.frames[-1])
        command(binary, data, "add", "Concurrent writer", success=False)

        session.send("e")
        session.send("\x15")
        session.type_text("Plan release revised")
        session.send("\r")
        session.send("p")
        session.send("/")
        session.type_text("revised")
        evidence.joinpath("search.ansi").write_bytes(session.frames[-1])
        session.send("\r")
        session.send("\x1b")
        session.send("?")
        evidence.joinpath("help.ansi").write_bytes(session.frames[-1])
        session.send("\x1b")
        session.click("[ ]")
        session.send("4")
        evidence.joinpath("done.ansi").write_bytes(session.frames[-1])
        session.send(" ")  # Reopen through the keyboard.
        session.send("1")
        session.send("d")
        evidence.joinpath("delete.ansi").write_bytes(session.frames[-1])
        session.send("\x1b")  # Cancellation preserves the task.
        session.resize(60, 24)
        os.kill(session.process.pid, signal.SIGWINCH)
        session.frame()
        evidence.joinpath("compact.ansi").write_bytes(session.frames[-1])
        session.finish()

    tasks = json.loads(command(binary, data, "list", "--all", "--json").stdout)
    assert len(tasks) == 1
    assert tasks[0]["title"] == "Plan release revised"
    assert tasks[0]["priority"] == "urgent"
    assert tasks[0]["due"] == "2030-12-31"
    assert tasks[0]["notes"] == "Read the rollout checklist"
    assert tasks[0]["completed"] is False

    with terminal(binary, data, 80, 24) as session:
        session.send("d")
        session.send("y")
        session.finish()
    assert json.loads(command(binary, data, "list", "--all", "--json").stdout) == []

    with terminal(binary, data) as session:
        os.kill(session.process.pid, signal.SIGTERM)
        session.process.wait(timeout=5)
        session.assert_restored()

    print("PASS: real PTY create/edit/priority/search/mouse/complete/reopen/delete/resize/cleanup")

def mouse_checks(binary: str, root: Path, evidence: Path) -> None:
    data = root / "mouse.json"

    with terminal(binary, data, 80, 24) as session:
        session.click("[New]")
        session.type_text("Mouse created")
        session.click("[Save]")
        session.click("[Edit]")
        session.type_text(" discarded")
        session.click("[Cancel]")
        session.click("3 All")
        session.click("[Del]")
        session.click("[Cancel]")
        session.finish()

    tasks = json.loads(command(binary, data, "list", "--all", "--json").stdout)
    assert len(tasks) == 1 and tasks[0]["title"] == "Mouse created"

    with terminal(binary, data, 80, 24) as session:
        session.send("d")
        session.click("[Delete]")
        session.finish()
    assert json.loads(command(binary, data, "list", "--all", "--json").stdout) == []

    with terminal(binary, data, 48, 20) as session:
        session.send("n")
        session.send("\x1b[200~中文\ncafe\u0301 \x1b[31mred\x1b[0m\x1b[201~")
        session.send("\r")
        evidence.joinpath("unicode-minimum.ansi").write_bytes(session.frames[-1])
        session.resize(40, 12)
        os.kill(session.process.pid, signal.SIGWINCH)
        session.frame()
        evidence.joinpath("too-small.ansi").write_bytes(session.frames[-1])
        session.finish()
    tasks = json.loads(command(binary, data, "list", "--json").stdout)
    assert tasks[0]["title"] == "中文 cafe\u0301 red"
    print("PASS: mouse actions/forms/confirmation, Unicode paste and minimum viewport")

def theme_checks(binary: str, root: Path, evidence: Path) -> None:
    data = root / "theme-data.json"
    theme = root / "theme.json"
    theme.write_text('{"background":"#202122","accent":"#C4A7E7"}', encoding="utf-8")

    with terminal(binary, data, theme=theme) as session:
        assert b"\x1b[48;2;32;33;34m" in session.frames[-1]
        evidence.joinpath("custom-theme.ansi").write_bytes(session.frames[-1])
        theme.write_text('{"background":"#302122","accent":"#C4A7E7"}', encoding="utf-8")
        assert b"\x1b[48;2;48;33;34m" in session.send("r")
        theme.write_text('{"background":"broken"}', encoding="utf-8")
        assert b"\x1b[48;2;48;33;34m" in session.send("r")
        evidence.joinpath("theme-error.ansi").write_bytes(session.frames[-1])
        session.finish()
    command(binary, data, "--theme", str(theme), "list", success=False)
    print("PASS: custom theme, live reload and invalid reload preserve the active palette")

def navigation_checks(binary: str, root: Path, evidence: Path) -> None:
    data = root / "navigation.json"
    for index in range(20):
        command(binary, data, "add", f"Task {index + 1:02}")

    with terminal(binary, data, 80, 24) as session:
        session.send("\x1b[6~")  # Page Down: select task 11 in a ten-row list.
        session.send(" ")
        session.send("\x1b[F")  # End: select task 20.
        session.send("\x1b[<64;20;10M")  # Wheel up one row: select task 19.
        session.send(" ")
        session.send("/")
        session.type_text("no such task")
        evidence.joinpath("no-results.ansi").write_bytes(session.frames[-1])
        session.send("\r")
        session.send("\x1b")
        session.send("n")
        session.type_text("Must not be saved")
        session.send("\t")
        session.send("\t")
        session.type_text("2030-02-30")
        session.send("\r")
        evidence.joinpath("form-error.ansi").write_bytes(session.frames[-1])
        session.send("\x1b")
        evidence.joinpath("scrolling.ansi").write_bytes(session.frames[-1])
        session.finish("\x03")

    tasks = json.loads(command(binary, data, "list", "--all", "--json").stdout)
    assert len(tasks) == 20
    assert sorted(task["id"] for task in tasks if task["completed"]) == [11, 19]
    print("PASS: page/end/wheel navigation, empty search, invalid form and Ctrl-C cleanup")

def scheduling_checks(binary: str, root: Path, evidence: Path) -> None:
    for columns, rows in [(120, 32), (60, 24), (48, 20)]:
        data = root / f"schedule-{columns}.json"
        command(binary, data, "add", "Drag this task", "--priority", "high")
        with terminal(binary, data, columns, rows) as session:
            before = date.today()
            session.drag("Drag this task", "Next week")
            after = date.today()
            stored = json.loads(data.read_text(encoding="utf-8"))["tasks"]
            # The action can cross local midnight; both bounded civil dates
            # are valid references, without waiting on or fixing the clock.
            assert stored[0]["due"] in {
                (reference + timedelta(days=7 - reference.weekday())).isoformat()
                for reference in (before, after)
            }
            evidence.joinpath(f"scheduled-{columns}.ansi").write_bytes(session.frames[-1])

            before = date.today()
            session.click("Tomorrow")
            after = date.today()
            stored = json.loads(data.read_text(encoding="utf-8"))["tasks"]
            assert stored[0]["due"] in {
                (reference + timedelta(days=1)).isoformat()
                for reference in (before, after)
            }
            session.click("No date")
            stored = json.loads(data.read_text(encoding="utf-8"))["tasks"]
            assert stored[0]["due"] == ""

            x, y = session.cell("Drag this task", min_row=8)
            session.send(f"\x1b[<0;{x};{y}M")
            session.send("\x1b[<32;1;1M")
            session.send("\x1b[<0;1;1m")  # Outside every scheduling target.
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["due"] == ""

            session.send(f"\x1b[<0;{x};{y}M")
            target_x, target_y = session.cell("Next week")
            session.send(f"\x1b[<32;{target_x};{target_y}M")
            evidence.joinpath(f"dragging-{columns}.ansi").write_bytes(session.frames[-1])
            session.send("\x1b")
            session.send(f"\x1b[<0;{target_x};{target_y}m")
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["due"] == ""

            session.send(f"\x1b[<0;{x};{y}M")
            session.send(f"\x1b[<0;{target_x};{target_y}m")
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["due"] == ""

            session.send(f"\x1b[<0;{x};{y}M")
            session.send(f"\x1b[<32;{target_x};{target_y}M")
            session.resize(columns + 1, rows + 1)
            os.kill(session.process.pid, signal.SIGWINCH)
            session.frame()
            target_x, target_y = session.cell("Next week")
            session.send(f"\x1b[<0;{target_x};{target_y}m")
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["due"] == ""
            session.finish()

    print("PASS: real mouse drag/drop, quick date clicks and safe cancellation at three widths")

def selected_id(frame: bytes) -> int:
    match = re.search(rb"#(\d+) /", frame)
    assert match, "No selected stable task ID in the detail row"
    return int(match[1])

def direct_field_checks(binary: str, root: Path, evidence: Path) -> None:
    for columns, rows in [(48, 20), (120, 32)]:
        data = root / f"direct-fields-{columns}.json"
        command(binary, data, "add", "First task", "--priority", "high", "--due", "2023-01-01")
        command(binary, data, "add", "Target task", "--priority", "low", "--due", "2024-12-15")
        command(binary, data, "add", "Other task", "--priority", "normal", "--due", "2025-02-02")
        original = data.read_bytes()
        list_width = columns - 34 if columns >= 110 else columns

        with terminal(binary, data, columns, rows) as session:
            assert selected_id(session.frames[-1]) == 1

            # Every rendered cell in both fields, not a guessed label offset.
            for x in range(list_width - 21, list_width):
                session.send("g")
                _, y = session.cell("Target task", min_row=8)
                session.send(f"\x1b[<0;{x};{y}M")
                frame = session.send(f"\x1b[<0;{x};{y}m")
                assert selected_id(frame) == 2
                assert data.read_bytes() == original, "Opening/releasing a field mutated storage"
                if x < list_width - 12:
                    for label in ("[low]", "[normal]", "[high]", "[urgent]"):
                        session.cell(label)
                    # Keyboard editing proves Priority, not Title, has focus.
                    session.send("\x15")
                    session.send("\x1b[200~urgent\x1b[201~")
                    session.click("[Cancel]")
                else:
                    session.cell("[Next]")
                    session.send("\x1b")
                assert data.read_bytes() == original

            # The cells immediately outside the fields remain selection/drag cells.
            for x in (list_width - 22, list_width):
                session.send("g")
                _, y = session.cell("Target task", min_row=8)
                session.send(f"\x1b[<0;{x};{y}M")
                frame = session.send(f"\x1b[<0;{x};{y}m")
                assert selected_id(frame) == 2
                session.cell("Target task", min_row=8)
                assert data.read_bytes() == original

            session.send("g")
            _, y = session.cell("Target task", min_row=8)
            x = list_width - 12
            session.send(f"\x1b[<0;{x};{y}M")
            session.send(f"\x1b[<0;{x};{y}m")
            evidence.joinpath(f"direct-calendar-{columns}.ansi").write_bytes(session.frames[-1])
            session.click("[31]")
            stored = {task["id"]: task for task in json.loads(data.read_text())["tasks"]}
            before = {task["id"]: task for task in json.loads(original)["tasks"]}
            assert stored[2] == {**before[2], "due": "2024-12-31"}
            assert stored[1] == before[1] and stored[3] == before[3]

            # Save a keyboard priority draft; stable selection follows the re-sort.
            session.send("g")
            _, y = session.cell("Target task", min_row=8)
            x = list_width - 21
            session.send(f"\x1b[<0;{x};{y}M")
            session.send(f"\x1b[<0;{x};{y}m")
            session.send("\x15")
            session.send("\x1b[200~urgent\x1b[201~")
            evidence.joinpath(f"direct-priority-{columns}.ansi").write_bytes(session.frames[-1])
            frame = session.click("[Save]")
            assert selected_id(frame) == 2
            assert session.cell("Target task", min_row=8)[1] == 8
            stored = {task["id"]: task for task in json.loads(data.read_text())["tasks"]}
            assert stored[2] == {**before[2], "due": "2024-12-31", "priority": 4}
            assert stored[1] == before[1] and stored[3] == before[3]

            # All four mouse choices remain drafts, and Esc discards each one.
            saved = data.read_bytes()
            for label in ("[low]", "[normal]", "[high]", "[urgent]"):
                session.send("G")
                session.send(f"\x1b[<0;{x};8M")
                session.send(f"\x1b[<0;{x};8m")
                session.click(label)
                session.send("\x1b")
                assert data.read_bytes() == saved

            evidence.joinpath(f"direct-sorted-{columns}.ansi").write_bytes(session.frames[-1])
            session.finish()

    print("PASS: exact direct-field intervals, nonselected IDs, release safety, Priority focus, Save/re-sort and Cancel")

def wheel_precision_checks(binary: str, root: Path, evidence: Path) -> None:
    for columns, rows in [(48, 20), (120, 32)]:
        data = root / f"wheel-precision-{columns}.json"
        for index in range(20):
            command(binary, data, "add", f"Wheel task {index + 1:02}")
        original = data.read_bytes()

        with terminal(binary, data, columns, rows) as session:
            down = "\x1b[<65;20;10M"
            up = "\x1b[<64;20;10M"
            assert selected_id(session.send(down)) == 2
            assert selected_id(session.send(up)) == 1

            # One write, no inter-event delays; assert every acknowledged frame.
            for event, expected in [(down, list(range(2, 21)) + [20] * 4),
                                    (up, list(range(19, 0, -1)) + [1] * 4)]:
                os.write(session.master, (event * len(expected)).encode())
                actual = [selected_id(session.frame()) for _ in expected]
                assert actual == expected, (actual, expected)

            # Wheel input must not change the stable ID captured by a drag.
            session.send("\x1b[<0;10;8M")
            assert selected_id(session.send(down)) == 1
            session.send("\x1b[<32;1;1M")
            assert selected_id(session.send(down)) == 1
            session.send("\x1b[<0;1;1m")
            evidence.joinpath(f"wheel-precision-{columns}.ansi").write_bytes(b"".join(session.frames))
            session.finish()

        assert data.read_bytes() == original

    print("PASS: one task per wheel event, undelayed bursts, both clamps and drag suppression")

def calendar_checks(binary: str, root: Path, evidence: Path) -> None:
    for columns, rows in [(120, 32), (48, 20)]:
        data = root / f"calendar-{columns}.json"
        command(binary, data, "add", "Calendar task", "--due", "2024-12-15")

        with terminal(binary, data, columns, rows) as session:
            session.click("[Date]")
            evidence.joinpath(f"calendar-december-{columns}.ansi").write_bytes(session.frames[-1])
            session.click("[Next]")
            evidence.joinpath(f"calendar-january-{columns}.ansi").write_bytes(session.frames[-1])
            session.click("[ 1]")
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["due"] == "2025-01-01"

            session.click("[Edit]")
            session.click("[Pick date]")
            session.click("[Prev]")
            session.click("[31]")
            session.click("[urgent]")
            session.click("[Cancel]")
            stored = json.loads(data.read_text(encoding="utf-8"))["tasks"][0]
            assert stored["due"] == "2025-01-01" and stored["priority"] == 2

            session.click("[Edit]")
            session.click("[Pick date]")
            session.click("[Prev]")
            session.click("[31]")
            session.click("[urgent]")
            evidence.joinpath(f"mouse-edited-{columns}.ansi").write_bytes(session.frames[-1])
            session.click("[Save]")
            stored = json.loads(data.read_text(encoding="utf-8"))["tasks"][0]
            assert stored["due"] == "2024-12-31" and stored["priority"] == 4
            session.click("/ Search")
            session.type_text("no calendar task")
            session.click("[Clear]")
            session.cell("Calendar task")
            session.click("[Help]")
            session.click("[Back]")
            x, y = session.cell("[Quit]")
            session.finish(f"\x1b[<0;{x};{y}M")

    print("PASS: clickable calendar, year boundary, priority selection and draft cancellation")

def description_checks(binary: str, root: Path, evidence: Path) -> None:
    title = "Review a long task title with all of its context preserved for readability"
    notes = "Opening paragraph with enough context to read comfortably.\n\n"
    notes += "\n\n".join(
        f"Paragraph {index:02}: preserve every useful detail, including 中文 and cafe\u0301."
        for index in range(1, 16)
    )
    notes += "\n\n" + "longword" * 20 + "\n\nEND_DESCRIPTION_SENTINEL"

    for columns, rows in [(120, 32), (48, 20)]:
        data = root / f"description-{columns}.json"
        command(binary, data, "add", title, "--priority", "high", "--notes", notes)
        command(binary, data, "add", "Second task", "--priority", "low", "--notes", "Second description")
        original = data.read_bytes()

        with terminal(binary, data, columns, rows) as session:
            if columns == 120:
                preview_x, preview_y = session.cell("Opening paragraph")
                for _ in range(12):
                    session.send(f"\x1b[<65;{preview_x};{preview_y}M")
                session.cell("END_DESCRIPTION_SENTINEL")
                for _ in range(12):
                    session.send(f"\x1b[<64;{preview_x};{preview_y}M")
                session.cell("Opening paragraph")
            evidence.joinpath(f"description-preview-{columns}.ansi").write_bytes(session.frames[-1])
            session.send("\x1b[200~q\x1b[201~")
            session.click("[Details]")
            evidence.joinpath(f"description-reader-{columns}.ansi").write_bytes(session.frames[-1])
            session.send("\x1b[F")
            session.cell("END_DESCRIPTION_SENTINEL")
            evidence.joinpath(f"description-last-{columns}.ansi").write_bytes(session.frames[-1])
            session.send("\x1b[H")
            for _ in range(40):
                session.send("\x1b[<65;6;10M")
            session.cell("END_DESCRIPTION_SENTINEL")
            session.send("\x1b[H")
            for _ in range(40):
                session.click("[Down]")
            session.cell("END_DESCRIPTION_SENTINEL")
            assert data.read_bytes() == original

            session.click("[Back]")
            session.send("j")
            session.click("[Details]")
            session.cell("Second description")
            session.click("[Back]")
            session.send("k")
            session.click("[Details]")
            session.cell("Opening paragraph")
            resized = (60, 24) if columns == 120 else (120, 32)
            session.resize(*resized)
            os.kill(session.process.pid, signal.SIGWINCH)
            session.frame()
            session.send("\x1b[F")
            session.cell("END_DESCRIPTION_SENTINEL")
            session.resize(columns, rows)
            os.kill(session.process.pid, signal.SIGWINCH)
            session.frame()
            session.click("[Edit]")
            session.click("[Edit description]")
            session.send("\x15")
            session.send("\x1b[200~Discard this\r\n\r\nmultiline draft\x1b[201~")
            session.send("\r")
            session.type_text("Another paragraph")
            assert data.read_bytes() == original
            session.click("[Back]")
            session.click("[Cancel]")
            assert data.read_bytes() == original

            session.send("e")
            session.click("[Edit description]")
            session.send("\x15")
            session.send("\x1b[200~First pasted paragraph\r\n\r\nLast pasted paragraph\titem\x1b[201~")
            session.send("\r")
            session.type_text("中文 cafe\u0301 END_EDITED_SENTINEL")
            evidence.joinpath(f"description-editor-{columns}.ansi").write_bytes(session.frames[-1])
            assert data.read_bytes() == original
            session.click("[Save]")
            expected = "First pasted paragraph\n\nLast pasted paragraph\titem\n中文 cafe\u0301 END_EDITED_SENTINEL"
            assert json.loads(data.read_text(encoding="utf-8"))["tasks"][0]["notes"] == expected
            session.click("[Details]")
            session.send("\x1b[F")
            session.cell("END_EDITED_SENTINEL")
            session.click("[Back]")
            session.send("d")
            session.send("\x1b[200~y\x1b[201~")
            assert len(json.loads(data.read_text(encoding="utf-8"))["tasks"]) == 2
            session.send("\x1b")
            session.finish()

    print("PASS: complete description reading, scrolling, resize, multiline paste and draft safety")

def cursor_boundary_checks(binary: str, root: Path) -> None:
    for columns, rows in [(48, 20), (120, 32)]:
        data = root / f"cursor-{columns}.json"
        line_width = columns - 5

        with terminal(binary, data, columns, rows) as session:
            session.send("n")
            session.type_text("Cursor boundary")
            session.click("[Edit description]")
            session.send("\x1b[200~" + "a" * (line_width * 2) + "\x1b[201~")
            session.send("\x1b[F")
            session.send("\x1b[A")
            session.type_text("X")
            session.click("[Save]")
            session.finish()

        notes = json.loads(command(binary, data, "list", "--json").stdout)[0]["notes"]
        assert notes == "a" * (line_width - 1) + "X" + "a" * (line_width + 1)

    print("PASS: vertical cursor movement stays on the requested soft-wrapped row")

def caret_rendering_checks(binary: str, root: Path, evidence: Path) -> None:
    data = root / "caret-rendering.json"
    title = "Alpha中文Beta"

    with terminal(binary, data, 48, 20) as session:
        session.send("n")
        session.type_text(title)
        for _ in range(4):
            frame = session.send("\x1b[D")
        assert session.cell(title) == (13, 9)
        assert b"\x1b[9;22H\x1b[?25h" in frame
        evidence.joinpath("caret-title.ansi").write_bytes(frame)

        session.click("[Edit description]")
        session.send("\x1b[200~regression baselines\x1b[201~")
        session.send("\x1b[<0;14;8M")
        frame = session.send("\x1b[<0;14;8m")
        assert session.cell("regression baselines") == (3, 8)
        assert b"\x1b[8;14H\x1b[?25h" in frame
        evidence.joinpath("caret-description.ansi").write_bytes(frame)
        frame = session.click("[Save]")
        assert b"\x1b[?25h" not in frame

        session.send("/")
        session.send("\x1b[200~" + title + "\x1b[201~")
        for _ in range(4):
            frame = session.send("\x1b[D")
        assert session.cell(title) == (12, 6)
        assert b"\x1b[6;21H\x1b[?25h" in frame
        evidence.joinpath("caret-search.ansi").write_bytes(frame)
        session.send("\x1b")
        session.finish()

    task = json.loads(command(binary, data, "list", "--json").stdout)[0]
    assert task["title"] == title and task["notes"] == "regression baselines"
    print("PASS: native edit cursor preserves text cells and Unicode positioning")

def grapheme_editing_checks(binary: str, root: Path, evidence: Path) -> None:
    clusters = [
        ("accent", "e\u0301", 1),
        ("modifier", "\U0001f44d\U0001f3fd", 2),
        ("profession", "\U0001f469\u200d\U0001f4bb", 2),
        ("family-three", "\U0001f468\u200d\U0001f469\u200d\U0001f467", 2),
        ("family-four", "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466", 2),
        ("flag", "\U0001f1e7\U0001f1f7", 2),
        ("cjk", "\u4e2d", 2),
        ("keycap", "1\ufe0f\u20e3", 2),
        ("presentation", "\u2764\ufe0f", 2),
    ]

    for columns, rows in [(48, 20), (120, 32)]:
        for label, cluster, width in clusters:
            # The four actions are the retained baseline's actual editing cases.
            operations = [
                ("backspace", ["\x1b[D", "\x7f"], "AB", 1),
                ("delete", ["\x1b[H", "\x1b[C", "\x1b[3~"], "AB", 1),
                ("right", ["\x1b[H", "\x1b[C", "\x1b[C", "X"], "A" + cluster + "XB", width + 2),
                ("left", ["\x1b[D", "\x1b[D", "X"], "AX" + cluster + "B", 2),
            ]
            for operation, actions, expected, caret in operations:
                for field, x, y in [("title", 13, 9), ("search", 12, 6), ("description", 3, 8)]:
                    name = f"grapheme-{label}-{operation}-{field}-{columns}"
                    data = root / f"{name}.json"
                    command(binary, data, "add", expected if field == "search" else "Grapheme regression")
                    original = data.read_bytes()

                    with terminal(binary, data, columns, rows) as session:
                        session.send("/" if field == "search" else "e")
                        if field == "description":
                            session.click("[Edit description]")
                        session.send("\x15")
                        initial = "A" + cluster + "B"
                        if operation == "left":
                            session.type_text(initial)
                            frame = session.frames[-1]
                        else:
                            frame = session.send("\x1b[200~" + initial + "\x1b[201~")
                        assert f"\x1b[{y};{x + width + 2}H\x1b[?25h".encode() in frame, name

                        for action in actions:
                            frame = session.send(action)
                        assert f"\x1b[{y};{x + caret}H\x1b[?25h".encode() in frame, name
                        evidence.joinpath(name + ".ansi").write_bytes(frame)
                        assert data.read_bytes() == original

                        if field == "search":
                            selected = re.search(rb"#(\d+) /", frame)
                            assert selected and int(selected[1]) == 1, name
                            runs = re.findall(rb"\x1b\[6;1H(.*?)(?=\x1b\[\d+;\d+H)", frame, re.S)
                            assert runs and expected.encode() in runs[-1], name
                            session.send("\x1b")
                        else:
                            session.click("[Save]")
                        session.finish()

                    task = json.loads(command(binary, data, "list", "--json").stdout)[0]
                    actual = task["notes" if field == "description" else "title"]
                    assert actual == expected, (name, actual, expected)
                    if field == "search":
                        assert data.read_bytes() == original
                    evidence.joinpath(name + ".json").write_text(json.dumps({
                        "initial": initial, "actions": actions, "expected": expected,
                        "actual": actual, "caret": [x + caret, y],
                    }, ensure_ascii=True, indent=2), encoding="utf-8")

        print(f"PASS: grapheme arrows/deletion, native caret and saved bytes in all three fields at {columns}x{rows}")

def grapheme_merge_checks(binary: str, root: Path, evidence: Path) -> None:
    woman, laptop = "\U0001f469", "\U0001f4bb"
    first, second, third = "\U0001f1fa", "\U0001f1f8", "\U0001f1e8"
    cases = [
        ("leading-mark", "\u0301B", ["\x1b[H", "e", "X"], "e\u0301XB", 2),
        ("join", woman + laptop + "B", ["\x1b[H", "\x1b[C", "\u200d", "X"], woman + "\u200d" + laptop + "XB", 3),
        ("ri-insert", second + third + "B", ["\x1b[H", first, "X"], first + second + "X" + third + "B", 3),
        ("ri-delete", first + "X" + second + third + "B", ["\x1b[H", "\x1b[C", "\x1b[3~", "Y"], "Y" + first + second + third + "B", 1),
        ("ri-backspace", first + "X" + second + third + "B", ["\x1b[H", "\x1b[C", "\x1b[C", "\x7f", "Y"], "Y" + first + second + third + "B", 1),
    ]
    for columns, rows in [(48, 20), (120, 32)]:
        for name, initial, actions, expected, caret in cases:
            for field, x, y in [("title", 13, 9), ("search", 12, 6), ("description", 3, 8)]:
                label = f"merge-{name}-{field}-{columns}"
                data = root / f"{label}.json"
                command(binary, data, "add", expected if field == "search" else "Merge regression")
                original = data.read_bytes()
                with terminal(binary, data, columns, rows) as session:
                    session.send("/" if field == "search" else "e")
                    if field == "description":
                        session.click("[Edit description]")
                    session.send("\x15")
                    session.send("\x1b[200~" + initial + "\x1b[201~")
                    for action in actions:
                        frame = session.send(action)
                    assert f"\x1b[{y};{x + caret}H\x1b[?25h".encode() in frame, label
                    evidence.joinpath(label + ".ansi").write_bytes(frame)
                    if field == "search":
                        selected = re.search(rb"#(\d+) /", frame)
                        assert selected and int(selected[1]) == 1, label
                        runs = re.findall(rb"\x1b\[6;1H(.*?)(?=\x1b\[\d+;\d+H)", frame, re.S)
                        assert runs and expected.encode() in runs[-1], label
                        session.send("\x1b")
                    else:
                        session.click("[Save]")
                    session.finish()
                task = json.loads(command(binary, data, "list", "--json").stdout)[0]
                assert task["notes" if field == "description" else "title"] == expected, label
                if field == "search":
                    assert data.read_bytes() == original

    print("PASS: insertion snaps forward and deletion snaps backward after whole-field resegmentation")

def grapheme_geometry_checks(binary: str, root: Path, evidence: Path) -> None:
    cluster = "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466"
    for columns, rows in [(48, 20), (120, 32)]:
        for field, x, y in [("title", 13, 9), ("search", 12, 6)]:
            width = columns - 22 if field == "search" else columns - (48 if columns >= 110 else 14)
            # Search leaves one extra display cell beyond its scrolling budget.
            run_width = width + (field == "search")
            text = "a" * (run_width - 1) + cluster + "B"
            data = root / f"viewport-{field}-{columns}.json"
            command(binary, data, "add", text)
            original = data.read_bytes()
            with terminal(binary, data, columns, rows) as session:
                session.send("/" if field == "search" else "e")
                if field == "search":
                    session.send("\x1b[200~" + text + "\x1b[201~")
                frame = session.send("\x1b[F")
                assert f"\x1b[{y};{x + width - 1}H\x1b[?25h".encode() in frame
                assert ("a" * (width - 4) + cluster + "B").encode() in frame

                session.send("\x1b[D")
                frame = session.send("\x1b[D")
                assert f"\x1b[{y};{x + width - 2}H\x1b[?25h".encode() in frame
                assert ("a" * (width - 2) + cluster).encode() in frame
                evidence.joinpath(f"viewport-{field}-{columns}.ansi").write_bytes(frame)

                frame = session.send("\x1b[H")
                run_x = 1 if field == "search" else x
                runs = re.findall(fr"\x1b\[{y};{run_x}H(.*?)(?=\x1b\[\d+;\d+H)".encode(), frame, re.S)
                # Ignore the initial row clear; inspect the actual positioned text run.
                assert runs and cluster.encode() not in runs[-1]
                assert ("a" * (run_width - 1) + " ").encode() in runs[-1]
                assert f"\x1b[{y};{x}H\x1b[?25h".encode() in frame
                session.send("\x1b")
                session.finish()
            assert data.read_bytes() == original

        # A two-cell family cannot be split into the one cell remaining on row one.
        line_width = columns - 5
        text = "a" * (line_width - 1) + cluster + "B"
        data = root / f"grapheme-wrap-{columns}.json"
        command(binary, data, "add", "Wrap regression", "--notes", text)
        original = data.read_bytes()
        with terminal(binary, data, columns, rows) as session:
            session.send("e")
            frame = session.click("[Edit description]")
            assert b"\x1b[9;6H\x1b[?25h" in frame
            frame = session.send("\x1b[A")
            assert b"\x1b[8;6H\x1b[?25h" in frame
            frame = session.send("\x1b[B")
            assert b"\x1b[9;6H\x1b[?25h" in frame
            for cell in (3, 4):
                session.send(f"\x1b[<0;{cell};9M")
                frame = session.send(f"\x1b[<0;{cell};9m")
                assert b"\x1b[9;3H\x1b[?25h" in frame
            session.send("\x1b[<0;5;9M")
            frame = session.send("\x1b[<0;5;9m")
            assert b"\x1b[9;5H\x1b[?25h" in frame
            session.send("\x1b[D")
            frame = session.send("X")
            assert b"\x1b[9;3H\x1b[?25h" in frame
            evidence.joinpath(f"grapheme-wrap-{columns}.ansi").write_bytes(frame)
            assert data.read_bytes() == original
            session.click("[Save]")
            session.finish()
        task = json.loads(command(binary, data, "list", "--json").stdout)[0]
        assert task["notes"] == "a" * (line_width - 1) + "X" + cluster + "B"

    print("PASS: whole-cluster viewport edges, wrapping, vertical movement and mouse cell mapping")

def normalized_limit_checks(binary: str, root: Path, evidence: Path) -> None:
    for columns, rows in [(48, 20), (120, 32)]:
        for field, limit in [("title", 4096), ("search", 1024)]:
            cases = [
                ("crlf", "A" * (limit - 2), "\r\nB", " B", True),
                ("cr-tab", "A" * (limit - 3), "\r\tB", "  B", True),
                ("exact-utf8", "A" * (limit - 4), "e\u0301B", "e\u0301B", True),
                ("reject-one-byte", "A" * (limit - 1), "\r\nB", "", False),
                ("reject-cluster", "A" * (limit - 1), "e\u0301B", "", False),
            ]
            for name, prefix, pasted, normalized, accepted in cases:
                label = f"limit-{name}-{field}-{columns}"
                expected = prefix + normalized if accepted else prefix[:-1] + "Z"
                data = root / f"{label}.json"
                command(binary, data, "add", expected if field == "search" else "Limit regression")
                original = data.read_bytes()
                with terminal(binary, data, columns, rows) as session:
                    session.send("/" if field == "search" else "e")
                    session.send("\x15")
                    before = session.send("\x1b[200~" + prefix + "\x1b[201~")
                    frame = session.send("\x1b[200~" + pasted + "\x1b[201~")
                    if not accepted:
                        cursor = rb"\x1b\[(\d+);(\d+)H\x1b\[\?25h"
                        assert re.findall(cursor, frame) == re.findall(cursor, before), label
                        session.send("\x7f")
                        frame = session.send("Z")
                    evidence.joinpath(label + ".ansi").write_bytes(frame)
                    if field == "search":
                        selected = re.search(rb"#(\d+) /", frame)
                        assert selected and int(selected[1]) == 1, label
                        # Matching alone is insufficient: the rejected prefix also matches.
                        runs = re.findall(rb"\x1b\[6;1H(.*?)(?=\x1b\[\d+;\d+H)", frame, re.S)
                        assert runs and expected[-10:].encode() in runs[-1], label
                        session.send("\x1b")
                    else:
                        session.click("[Save]")
                    session.finish()
                task = json.loads(command(binary, data, "list", "--json").stdout)[0]
                assert task["title"] == expected, label
                if field == "search":
                    assert data.read_bytes() == original

        data = root / f"oversized-loaded-{columns}.json"
        command(binary, data, "add", "A" * 4100)
        with terminal(binary, data, columns, rows) as session:
            session.send("e")
            session.send("\x1b[H")
            session.send("\x1b[3~")
            session.send("X")  # Still over budget: insertion is rejected, deletion remains valid.
            session.send("\x1b[F")
            session.send("\x7f")
            session.click("[Edit description]")
            session.send("\x1b[200~" + "N" * 5000 + "\r\n\tB\x1b[201~")
            session.click("[Save]")
            session.finish()
        task = json.loads(command(binary, data, "list", "--json").stdout)[0]
        assert task["title"] == "A" * 4098
        assert task["notes"] == "N" * 5000 + "\n\tB"

    print("PASS: normalized 4096/1024-byte limits, whole-event rejection and editable oversized fields")

def motion_checks(binary: str, root: Path, evidence: Path) -> None:
    """Measure a traveling band on actual emitted cells, not a global fade."""
    def row_run(frame: bytes, row: int, column: int = 1) -> bytes:
        matches = re.findall(fr"\x1b\[{row};{column}H(.*?)(?=\x1b\[\d+;\d+H)".encode(), frame, re.S)
        run = matches[-1] if matches else b""
        if column == 1:
            # line() establishes the default palette before painting content.
            run = re.sub(rb"^\x1b\[48;2;[\d;]+m\x1b\[38;2;[\d;]+m", b"", run)
        return run

    def backgrounds(run: bytes) -> list[tuple[int, ...]]:
        # The measured rows use ASCII, so each printable byte is one cell.
        result: list[tuple[int, ...]] = []
        color: tuple[int, ...] = ()
        for part in re.split(rb"(\x1b\[[0-?]*[ -/]*[@-~])", run):
            match = re.fullmatch(rb"\x1b\[48;2;(\d+);(\d+);(\d+)m", part)
            if match:
                color = tuple(map(int, match.groups()))
            elif not part.startswith(b"\x1b"):
                result.extend([color] * len(part))
        return result

    def still(session: TerminalSession, label: str) -> None:
        assert not session.pending, label
        assert not session.selector.select(timeout=0.3), label

    def sweep(session: TerminalSession, initial: bytes, row: int, column: int,
              width: int, base: tuple[int, ...], label: str) -> None:
        ticks: list[bytes] = []
        positions: list[float] = []
        samples: list[dict[str, object]] = []
        started = monotonic()
        deadline = started + 4
        # Ordinary ink starts background, foreground. Active shimmer starts
        # foreground, background. Wait for the actual settled row, not time.
        ordinary = f"\x1b[48;2;{base[0]};{base[1]};{base[2]}m\x1b[38;2;".encode()

        while True:
            assert monotonic() < deadline, f"{label}: sweep did not settle"
            tick = session.frame(full=False)
            ticks.append(tick)
            run = row_run(tick, row, column)
            cells = backgrounds(run)
            if cells:
                assert len(cells) == width, (label, len(cells), width)
                band = [index for index, color in enumerate(cells) if color != base]
                if band:
                    assert len(band) < width * 0.4, f"{label}: global brightness, not a narrow band"
                    assert band == list(range(band[0], band[-1] + 1)), label
                    positions.append(sum(band) / len(band))
                samples.append({"elapsed": monotonic() - started, "band": band})
                if positions and not band and run.startswith(ordinary):
                    break

        assert len(positions) >= 5, (label, positions)
        assert min(positions) < width * 0.25 and max(positions) > width * 0.75, (label, positions)
        assert all(a <= b for a, b in zip(positions, positions[1:])), (label, positions)
        assert all(len(tick) < len(initial) // 2 for tick in ticks), label
        assert all(b"\x1b[?2026h" in tick and b"\x1b[?2026l" in tick for tick in ticks), label
        assert all(b"\x1b[2J" not in tick and b"\x1b[1;1H" not in tick for tick in ticks), label
        evidence.joinpath(label + ".ansi").write_bytes(initial + b"".join(ticks))
        evidence.joinpath(label + ".json").write_text(json.dumps(samples, indent=2))
        still(session, f"{label}: settled motion emitted idle output")

    for columns, rows in [(48, 20), (80, 24), (120, 32), (120, 40)]:
        data = root / f"motion-{columns}-{rows}.json"
        # Rows with Unicode are checked separately for intact color-run clusters.
        clusters = ("e\u0301", "\U0001f469\u200d\U0001f4bb", "\U0001f1fa\U0001f1f8", "1\ufe0f\u20e3")
        command(binary, data, "add", " ".join(clusters), "--notes", "Keep the store unchanged")
        command(binary, data, "add", "Second focus target")
        original = data.read_bytes()
        list_width = columns - 34 if columns >= 110 else columns

        with terminal(binary, data, columns, rows, reduced_motion=False) as session:
            still(session, "Startup without a transition must stay idle")
            initial = session.send("j")
            assert selected_id(initial) == 2
            assert backgrounds(row_run(initial, 9))[0] == (28, 59, 73), "Selection was delayed"
            sweep(session, initial, 9, 1, list_width - 1, (28, 59, 73), f"focus-{columns}-{rows}")
            assert data.read_bytes() == original

            # A status-only transition has a moving band, not a brand/global pulse.
            initial = session.send("r")
            sweep(session, initial, rows - 2, 1, columns, (9, 20, 29), f"status-{columns}-{rows}")

            x, y = session.cell("Second focus target", min_row=8)
            session.send(f"\x1b[<0;{x};{y}M")
            target_x, target_y = session.cell("Tomorrow")
            initial = session.send(f"\x1b[<32;{target_x};{target_y}M")
            target_width = 30 if columns >= 110 else (columns - 4) // 3
            target_column = columns - 31 if columns >= 110 else target_x - 1
            sweep(session, initial, target_y, target_column, target_width,
                  (28, 59, 73), f"drop-{columns}-{rows}")
            session.send("\x1b")
            session.send(f"\x1b[<0;{target_x};{target_y}m")

            # Interrupt an active transition with another selection. Input is
            # acknowledged as a complete frame, never queued behind animation.
            frame = session.send("k")
            assert selected_id(frame) == 1
            unicode_frames = [frame]
            for _ in range(8):
                unicode_frames.append(session.frame(full=False))
            for frame in unicode_frames:
                run = row_run(frame, 8)
                if run:
                    for cluster in clusters:
                        assert cluster.encode() in run, "ANSI split a grapheme cluster"
            evidence.joinpath(f"shimmer-graphemes-{columns}-{rows}.ansi").write_bytes(b"".join(unicode_frames))
            assert selected_id(session.send("j")) == 2
            session.send("m")
            still(session, "Reduced motion emitted an idle frame")
            session.click("[FX:off]")
            session.frame(full=False)
            session.send("n")
            still(session, "Editing did not stop animation")
            session.click("[Edit description]")
            still(session, "Description editing emitted animation")
            session.send("\x1b")
            session.send("/")
            still(session, "Search emitted animation")
            session.send("\x1b")
            session.send("?")
            still(session, "Help emitted animation")
            session.send("\x1b")
            session.resize(columns + 1, rows + 1)
            os.kill(session.process.pid, signal.SIGWINCH)
            session.frame()
            session.send("m")
            session.finish()

        assert data.read_bytes() == original

    print("PASS: moving focus/drop/status bands, whole graphemes, immediate input, finite idle-free motion, still modes and resize")

def help_checks(binary: str, root: Path) -> None:
    def position(frame: bytes) -> tuple[int, int, int]:
        match = re.search(rb"(\d+)-(\d+) / (\d+) lines", frame)
        assert match, "Help must expose its scroll position"
        return tuple(map(int, match.groups()))

    for columns, rows in [(48, 20), (95, 24), (96, 24), (120, 32)]:
        data = root / f"help-{columns}.json"
        command(binary, data, "add", "Help regression task")
        original = data.read_bytes()

        with terminal(binary, data, columns, rows) as session:
            first = session.send("?")
            start, end, total = position(first)
            assert start == 1 and end == min(total, rows - 9)
            assert b"Help regression task" not in first
            assert b"[Calendar]" not in first

            page = session.send("\x1b[6~")
            assert position(page)[0] == min(1 + rows - 9, max(1, total - (rows - 9) + 1))
            assert position(session.send("\x1b[F"))[1] == total
            assert position(session.send("\x1b[H"))[0] == 1
            session.click("[Down]")
            assert position(session.frames[-1])[0] == min(4, max(1, total - (rows - 9) + 1))
            session.click("[Up]")
            assert position(session.frames[-1])[0] == 1

            session.send("\x1b[F")
            session.resize(120 if columns < 96 else 48, 24)
            os.kill(session.process.pid, signal.SIGWINCH)
            start, end, total = position(session.frame())
            assert 1 <= start <= end <= total
            session.click("[Back]")
            session.cell("Help regression task")
            session.finish()

        assert data.read_bytes() == original

    print("PASS: dedicated help, page/home/end scrolling, controls and responsive reflow")

def main() -> None:
    binary = str(Path(sys.argv[1]).resolve())

    with tempfile.TemporaryDirectory(prefix="dtask-integration-") as directory:
        root = Path(directory)
        evidence = Path(os.environ.get("DTASK_EVIDENCE_DIR", str(root / "captures")))
        evidence.mkdir(parents=True, exist_ok=True)
        cli_checks(binary, root)
        cli_option_checks(binary, root)
        tui_checks(binary, root, evidence)
        mouse_checks(binary, root, evidence)
        theme_checks(binary, root, evidence)
        navigation_checks(binary, root, evidence)
        scheduling_checks(binary, root, evidence)
        direct_field_checks(binary, root, evidence)
        wheel_precision_checks(binary, root, evidence)
        calendar_checks(binary, root, evidence)
        description_checks(binary, root, evidence)
        cursor_boundary_checks(binary, root)
        caret_rendering_checks(binary, root, evidence)
        grapheme_editing_checks(binary, root, evidence)
        grapheme_merge_checks(binary, root, evidence)
        grapheme_geometry_checks(binary, root, evidence)
        normalized_limit_checks(binary, root, evidence)
        motion_checks(binary, root, evidence)
        help_checks(binary, root)

    print("PASS: all integration checks")

if __name__ == "__main__":
    main()
