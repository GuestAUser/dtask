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
import unicodedata
from contextlib import contextmanager
from collections.abc import Iterator

class TerminalSession:
    """Own a real PTY and subscribe to complete frames before sending input."""

    def __init__(self, binary: str, data: Path, columns: int, rows: int, theme: Path | None = None) -> None:
        self.master, self.slave = pty.openpty()
        self.rows = rows
        self.columns = columns
        fcntl.ioctl(self.slave, termios.FIONREAD, struct.pack("i", 0))
        self.original = termios.tcgetattr(self.slave)
        self.pending = b""
        self.frames: list[bytes] = []
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
            env={**os.environ, "TERM": "xterm-256color", "LC_ALL": "C.UTF-8"},
        )
        self.frame()

    def resize(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def frame(self) -> bytes:
        """A full final row plus reset is the renderer's completion boundary."""
        marker = f"\x1b[{self.rows};1H".encode()

        while True:
            start = self.pending.find(marker)
            end = self.pending.find(b"\x1b[0m", start) if start >= 0 else -1

            if end >= 0:
                result = self.pending[: end + 4]
                self.pending = self.pending[end + 4 :]
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
        rows = re.split(rb"\x1b\[(\d+);(\d+)H", self.frames[-1])
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
def terminal(binary: str, data: Path, columns: int = 120, rows: int = 32, theme: Path | None = None) -> Iterator[TerminalSession]:
    session = TerminalSession(binary, data, columns, rows, theme)
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
    assert data.read_bytes() == before

    corrupt = root / "corrupt.json"
    corrupt.write_text("{invalid", encoding="utf-8")
    command(binary, corrupt, "add", "Must not overwrite", success=False)
    assert corrupt.read_text(encoding="utf-8") == "{invalid"
    command(binary, data, success=False)  # Pipes are not interactive terminals.
    print("PASS: CLI persistence, sorting, completion, deletion, invalid input, corruption and non-TTY")

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
        session.send("\x1b[<64;20;10M")  # Wheel up three rows: select task 17.
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
    assert sorted(task["id"] for task in tasks if task["completed"]) == [11, 17]
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

def main() -> None:
    binary = str(Path(sys.argv[1]).resolve())

    with tempfile.TemporaryDirectory(prefix="dtask-integration-") as directory:
        root = Path(directory)
        evidence = Path(os.environ.get("DTASK_EVIDENCE_DIR", str(root / "captures")))
        evidence.mkdir(parents=True, exist_ok=True)
        cli_checks(binary, root)
        tui_checks(binary, root, evidence)
        mouse_checks(binary, root, evidence)
        theme_checks(binary, root, evidence)
        navigation_checks(binary, root, evidence)
        scheduling_checks(binary, root, evidence)
        calendar_checks(binary, root, evidence)
        description_checks(binary, root, evidence)
        cursor_boundary_checks(binary, root)
        caret_rendering_checks(binary, root, evidence)

    print("PASS: all integration checks")

if __name__ == "__main__":
    main()
