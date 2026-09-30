module model_test;

import dtask.model;
import core.stdc.errno : errno, EINTR;
import core.sys.posix.fcntl : open, fcntl, O_RDONLY, F_GETFD, FD_CLOEXEC;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.stdlib : mkdtemp;
import core.sys.posix.sys.stat : stat_t, stat, fstat, chmod, mkfifo;
import core.sys.posix.sys.wait : waitpid, WIFEXITED, WEXITSTATUS;
import core.sys.posix.unistd : fork, pipe, readFD = read, writeFD = write,
    closeFD = close, _exit, getpid, symlink, link;
import core.time : dur;
import std.conv : to, octal;
import std.datetime : Date;
import std.exception : assertThrown, errnoEnforce;
import std.file : exists, readText, read, write, remove, rmdirRecurse, tempDir,
    dirEntries, SpanMode;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : toStringz, fromStringz, replace;

// Each test owns a unique directory. No fixture reads or writes the user's data.
private class Sandbox
{
    string directory;
    string path;

    this()
    {
        auto pattern = (buildPath(tempDir(), "dtask-model-XXXXXX") ~ '\0').dup;
        auto result = mkdtemp(pattern.ptr);
        errnoEnforce(result !is null, "Cannot create model test directory");
        directory = fromStringz(result).idup;
        path = buildPath(directory, "tasks.json");
    }

    void close()
    {
        rmdirRecurse(directory);
    }
}

private enum validStorage =
    `{"version":1,"tasks":[{"id":1,"title":"Keep me","notes":"notes","priority":2,`
    ~ `"due":"2024-02-29","completed":false,"created":"2024-01-01"}]}`;

private Task task(ulong id, Priority priority, string due = "", bool completed = false)
{
    return Task(id, "Task " ~ to!string(id), "", priority, due, completed, "2024-01-01");
}

private ulong[] orderedIDs(const(Task)[] tasks, string filter = "all", string query = "")
{
    ulong[] result;

    foreach (i; sortedIndices(tasks, filter, query))
        result ~= tasks[i].id;

    return result;
}

// ---- Civil dates and priority parsing ----------------------------------------

unittest
{
    foreach (valid; ["0001-01-01", "2000-02-29", "2024-02-29", "9999-12-31"])
        assert(normalizeDue(valid) == valid);

    assert(normalizeDue("") == "");
    assert(normalizeDue("  2024-02-29  ") == "2024-02-29");
    assert(daysUntil("") == int.max);

    foreach (invalid; ["0000-01-01", "1900-02-29", "2023-02-29", "2024-04-31",
        "2024-00-01", "2024-13-01", "2024-01-00", "2024-1-01", "2024-01-1",
        "10000-01-01", "2024-01-01junk", "next fortnight", "+d", "+-1d", "+1.5d",
        "+18446744073709551615d", "+99999999999999999999999999999999999999999d"])
    {
        assertThrown!Exception(normalizeDue(invalid));
    }

    assertThrown!Exception(daysUntil("today"));
    assertThrown!Exception(daysUntil("2023-02-29"));
}

// ---- Deterministic natural-date presets and calendar boundaries --------------

unittest
{
    foreach (input; ["", "  ", "none", "NO DATE", " clear ", "\tNo  \nDate\t"])
        assert(normalizeDue(input, "2024-02-29") == "");

    foreach (input; ["today", "TOD", "  ToDaY\t", "+0d", "in 0 days", " +000D "])
        assert(normalizeDue(input, "2024-02-29") == "2024-02-29");

    foreach (input; ["tomorrow", "TOM", "+1d", "in 1 days", " IN\t 1 \n DAYS "])
        assert(normalizeDue(input, "2024-02-29") == "2024-03-01");

    assert(normalizeDue(" YESTERDAY ", "2024-03-01") == "2024-02-29");
    assert(normalizeDue(" 2024-02-29 ", "2023-01-01") == "2024-02-29");

    // Reference dates remain strict ISO civil dates, even for absolute dates
    // and clears that do not otherwise need arithmetic.
    foreach (reference; ["", "today", " 2024-02-29 ", "2024-2-29", "0000-01-01",
        "1900-02-29", "2023-02-29", "2024-04-31", "2024-13-01", "10000-01-01"])
    {
        foreach (input; ["today", "", "clear", "2024-02-29"])
            assertThrown!Exception(normalizeDue(input, reference));
    }
}

unittest
{
    // Sunday and Monday distinguish a future occurrence from this week.
    static immutable names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
    static immutable fromSunday = ["2024-06-09", "2024-06-03", "2024-06-04", "2024-06-05",
        "2024-06-06", "2024-06-07", "2024-06-08"];
    static immutable fromMonday = ["2024-06-09", "2024-06-10", "2024-06-04", "2024-06-05",
        "2024-06-06", "2024-06-07", "2024-06-08"];
    static immutable sameWeekdays = ["2024-06-02", "2024-06-03", "2024-06-04", "2024-06-05",
        "2024-06-06", "2024-06-07", "2024-06-08"];
    static immutable nextWeekdays = ["2024-06-09", "2024-06-10", "2024-06-11", "2024-06-12",
        "2024-06-13", "2024-06-14", "2024-06-15"];

    foreach (i, name; names)
    {
        foreach (input; [name, name[0 .. 3], "next " ~ name, "next " ~ name[0 .. 3]])
        {
            assert(normalizeDue(input, "2024-06-02") == fromSunday[i]);
            assert(normalizeDue(input, "2024-06-03") == fromMonday[i]);
            assert(normalizeDue(input, sameWeekdays[i]) == nextWeekdays[i]);
        }
    }

    assert(normalizeDue(" NeXt\tMONDAY ", "2024-06-03") == "2024-06-10");
    assert(normalizeDue(" SUN ", "2024-06-02") == "2024-06-09");
    assert(normalizeDue("next week", "2024-06-02") == "2024-06-03");
    assert(normalizeDue("NEXT  WEEK", "2024-06-03") == "2024-06-10");

    foreach (i, reference; sameWeekdays)
    {
        auto expectedMonday = i == 0 ? "2024-06-03" : "2024-06-10";

        assert(normalizeDue("next week", reference) == expectedMonday);
        assert(normalizeDue("weekend", reference) == "2024-06-08");
        assert(normalizeDue(" THIS\tWEEKEND ", reference) == "2024-06-08");
    }

    assert(normalizeDue("weekend", "2024-06-09") == "2024-06-15");
}

unittest
{
    // Fixed results exercise month ends, leap rules, and year rollover without
    // depending on the machine's clock, timezone, or daylight-saving changes.
    foreach (testCase; [
        ["tom", "2024-01-31", "2024-02-01"],
        ["tomorrow", "2024-02-28", "2024-02-29"],
        ["tomorrow", "2023-02-28", "2023-03-01"],
        ["tomorrow", "1900-02-28", "1900-03-01"],
        ["tomorrow", "2000-02-28", "2000-02-29"],
        ["yesterday", "2000-03-01", "2000-02-29"],
        ["yesterday", "1900-03-01", "1900-02-28"],
        ["yesterday", "2024-01-01", "2023-12-31"],
        ["tomorrow", "2024-12-31", "2025-01-01"],
        ["+2d", "2024-02-28", "2024-03-01"],
        ["in 366 days", "2024-01-01", "2025-01-01"],
        ["next week", "2023-12-31", "2024-01-01"],
        ["next week", "2024-01-01", "2024-01-08"],
        ["next week", "2024-12-30", "2025-01-06"],
        ["weekend", "2024-02-29", "2024-03-02"],
        ["this weekend", "2023-12-31", "2024-01-06"],
        ["next thursday", "2024-02-28", "2024-02-29"],
        ["thu", "2024-02-29", "2024-03-07"],
        ["wednesday", "2024-12-31", "2025-01-01"]])
    {
        assert(normalizeDue(testCase[0], testCase[1]) == testCase[2]);
    }
}

unittest
{
    assert(normalizeDue("yesterday", "0001-01-02") == "0001-01-01");
    assert(normalizeDue("tomorrow", "9999-12-30") == "9999-12-31");
    assert(normalizeDue("+3652058d", "0001-01-01") == "9999-12-31");
    assert(normalizeDue("in 3652058 days", "0001-01-01") == "9999-12-31");
    assert(normalizeDue("weekend", "9999-12-25") == "9999-12-25");

    foreach (reference; ["0001-01-01", "9999-12-31"])
    {
        foreach (input; ["today", "tod", "+0d", "in 0 days"])
            assert(normalizeDue(input, reference) == reference);

        assert(normalizeDue("none", reference) == "");
    }

    assertThrown!Exception(normalizeDue("yesterday", "0001-01-01"));
    assertThrown!Exception(normalizeDue("+3652059d", "0001-01-01"));

    foreach (input; ["tomorrow", "tom", "+1d", "in 1 days", "next week", "weekend",
        "this weekend", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "next friday"])
    {
        assertThrown!Exception(normalizeDue(input, "9999-12-31"));
    }

    foreach (input; ["+", "+d", "+-1d", "+1.5d", "+1", "+1dd", "+ 1d", "in",
        "in days", "in -1 days", "in 1.5 days", "in one days", "in 1 day", "in 1 days extra",
        "next", "next fortnight", "next monday extra", "mondayish", "no dates",
        "+18446744073709551615d", "+18446744073709551616d",
        "+99999999999999999999999999999999999999999d",
        "in 18446744073709551616 days", "in 99999999999999999999999999999999999999999 days"])
    {
        assertThrown!Exception(normalizeDue(input, "2024-02-29"));
    }
}

unittest
{
    // Bracket real-clock calls with civil dates so a midnight boundary is valid,
    // not a flaky failure. The arithmetic itself is checked against Date.
    foreach (input, offset; ["today": 0, "tomorrow": 1, "+0d": 0, "+17d": 17])
    {
        auto before = Date.fromISOExtString(todayISO());
        auto actual = Date.fromISOExtString(normalizeDue(input));
        auto after = Date.fromISOExtString(todayISO());
        assert(actual >= before + dur!"days"(offset));
        assert(actual <= after + dur!"days"(offset));
    }

    auto before = Date.fromISOExtString(todayISO());
    auto actual = daysUntil("2024-02-29");
    auto after = Date.fromISOExtString(todayISO());
    assert(actual >= (Date(2024, 2, 29) - after).total!"days");
    assert(actual <= (Date(2024, 2, 29) - before).total!"days");
}

unittest
{
    foreach (priority; [Priority.low, Priority.normal, Priority.high, Priority.urgent])
    {
        assert(parsePriority(priorityLabel(priority)) == priority);
        assert(parsePriority(to!string(cast(int) priority)) == priority);
    }

    assert(parsePriority(" HIGH ") == Priority.high);

    foreach (invalid; ["", "0", "5", "-1", "2.0", "important"])
        assertThrown!Exception(parsePriority(invalid));

    assertThrown!Exception(priorityLabel(cast(Priority) 0));
    assertThrown!Exception(priorityLabel(cast(Priority) 5));
}

// ---- Filtering and the complete lexicographic rank ---------------------------

unittest
{
    Task[] tasks = [
        task(8, Priority.urgent, "9999-12-31", true),
        task(7, Priority.urgent),
        task(6, Priority.high, "9999-12-31"),
        task(5, Priority.high, "9999-01-01"),
        task(4, Priority.high, "9999-01-01"),
        task(3, Priority.low, "0001-01-01"),
        task(2, Priority.high, "0001-01-02"),
        task(1, Priority.urgent, "0001-01-01", true),
        task(9, Priority.high)
    ];

    auto snapshot = tasks.dup;
    assert(orderedIDs(tasks) == [2UL, 3, 7, 4, 5, 6, 9, 1, 8]);
    assert(orderedIDs(tasks, "open") == [2UL, 3, 7, 4, 5, 6, 9]);
    assert(orderedIDs(tasks, "done") == [1UL, 8]);
    assert(orderedIDs(tasks, "today") == [2UL, 3]);
    assert(tasks == snapshot);
    assertThrown!Exception(sortedIndices(tasks, "unknown", ""));
    assert(sortedIndices(null, "all", "").length == 0);
}

unittest
{
    auto value = Task(1, "Ship Release", "Review the API", Priority.normal,
        todayISO(), false, "2024-01-01");
    assert(matchesTask(value, "SHIP"));
    assert(matchesTask(value, "api"));
    assert(matchesTask(value, ""));
    assert(!matchesTask(value, "missing"));
    assert(orderedIDs([value], "today", "release") == [1UL]);
    assert(orderedIDs([value], "today", "missing").length == 0);
}

// ---- Persistent mutations and private file permissions -----------------------

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    assert(store.tasks.length == 0);
    assert(!exists(box.path));

    auto first = store.add("  First  ", Priority.high, "2024-02-29", "line one\nline two\tend");
    auto second = store.add("Second", Priority.low, "");
    assert(first == 1 && second == 2);
    assert(store.tasks[0].title == "First");
    assert(normalizeDue(store.tasks[0].created) == store.tasks[0].created);

    auto originalCreated = store.tasks[0].created;
    store.update(first, "Edited", Priority.urgent, "2030-12-31", "new notes");
    store.toggle(first);
    assert(store.tasks[0].completed);
    assert(store.tasks[0].created == originalCreated);
    store.toggle(first);
    assert(!store.tasks[0].completed);

    auto snapshot = store.tasks.dup;
    store.load();
    assert(store.tasks == snapshot);
    store.close();
    store.close();
    store = new TaskStore(box.path);
    assert(store.tasks == snapshot);
    store.remove(second);
    assert(store.tasks.length == 1 && store.tasks[0].id == first);
    store.load();
    assert(store.tasks.length == 1);

    auto parsed = parseJSON(readText(box.path));
    assert(parsed["version"].integer == 1);
    assert(parsed["tasks"].array.length == 1);
    assert(parsed["tasks"][0]["title"].str == "Edited");

    foreach (path; [box.path, box.path ~ ".lock"])
    {
        stat_t info;
        assert(stat(toStringz(path), &info) == 0);
        assert((info.st_mode & octal!"777") == octal!"600");
    }

    foreach (entry; dirEntries(box.directory, SpanMode.shallow))
        assert(entry.name == box.path || entry.name == box.path ~ ".lock");
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    assert(chmod(toStringz(box.directory), octal!"750") == 0);
    auto path = buildPath(box.directory, "new", "nested", "tasks.json");
    auto store = new TaskStore(path);
    scope (exit) store.close();
    store.add("Private", Priority.normal, "");

    stat_t info;
    assert(stat(toStringz(box.directory), &info) == 0);
    assert((info.st_mode & octal!"777") == octal!"750");
    assert(stat(toStringz(buildPath(box.directory, "new")), &info) == 0);
    assert((info.st_mode & octal!"777") == octal!"700");
    assert(stat(toStringz(buildPath(box.directory, "new", "nested")), &info) == 0);
    assert((info.st_mode & octal!"777") == octal!"700");
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    auto id = store.add("Keep me", Priority.normal, "");
    auto snapshot = store.tasks.dup;
    auto bytes = readText(box.path);

    foreach (title; ["", "   ", "bad\nline", "trailing\n", "\tleading", "bad\0text",
        "bad\x1b[31m", "bad\u0085text", "\xff"])
    {
        assertThrown!Exception(store.add(title, Priority.normal, ""));
        assertThrown!Exception(store.update(id, title, Priority.normal, "", ""));
    }

    assertThrown!Exception(store.add("Wrong priority", cast(Priority) 0, ""));
    assertThrown!Exception(store.update(id, "Wrong", cast(Priority) 5, "", ""));
    assertThrown!Exception(store.add("Wrong date", Priority.normal, "2024-02-30"));
    assertThrown!Exception(store.update(id, "Wrong", Priority.normal, "day before yesterday", ""));
    assertThrown!Exception(store.add("Wrong notes", Priority.normal, "", "\x1b[2J"));
    assertThrown!Exception(store.update(999, "Missing", Priority.normal, "", ""));
    assertThrown!Exception(store.toggle(999));
    assertThrown!Exception(store.remove(999));
    assert(store.tasks == snapshot);
    assert(readText(box.path) == bytes);

    store.close();
    assertThrown!Exception(store.load());
    assertThrown!Exception(store.add("Closed", Priority.normal, ""));
    assertThrown!Exception(store.update(id, "Closed", Priority.normal, "", ""));
    assertThrown!Exception(store.toggle(id));
    assertThrown!Exception(store.remove(id));
    assert(store.tasks == snapshot);
}

// ---- Refuse malformed storage, never repair it by overwriting -----------------

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();

    string[] invalid = ["", "{", "null", "[]", "{}", "{\"version\":1}",
        validStorage ~ " trailing", replace(validStorage, `"version":1`, `"version":2`),
        replace(validStorage, `"version":1`, `"version":"1"`),
        replace(validStorage, `"version":1`, `"version":1,"extra":0`),
        replace(validStorage, `"version":1`, `"version":1,"version":1`),
        replace(validStorage, `"id":1`, `"id":1,"id":2`),
        replace(validStorage, `"id":1`, `"id":0`),
        replace(validStorage, `"id":1`, `"id":-1`),
        replace(validStorage, `"id":1`, `"id":1.0`),
        replace(validStorage, `"id":1`, `"id":"1"`),
        replace(validStorage, `"title":"Keep me"`, `"title":false`),
        replace(validStorage, `"title":"Keep me"`, `"title":"   "`),
        replace(validStorage, `"title":"Keep me"`, `"title":"bad\u001b"`),
        replace(validStorage, `"notes":"notes"`, `"notes":null`),
        replace(validStorage, `"priority":2`, `"priority":0`),
        replace(validStorage, `"priority":2`, `"priority":5`),
        replace(validStorage, `"priority":2`, `"priority":2.0`),
        replace(validStorage, `"priority":2`, `"priority":"high"`),
        replace(validStorage, `"completed":false`, `"completed":0`),
        replace(validStorage, `"due":"2024-02-29"`, `"due":"today"`),
        replace(validStorage, `"due":"2024-02-29"`, `"due":"2023-02-29"`),
        replace(validStorage, `"created":"2024-01-01"`, `"created":""`),
        replace(validStorage, `"created":"2024-01-01"`, `"created":"2024-13-01"`),
        replace(validStorage, `"notes":"notes",`, ""),
        validStorage ~ "\xff"];

    auto duplicate = parseJSON(validStorage);
    duplicate["tasks"].array ~= duplicate["tasks"].array[0];
    invalid ~= duplicate.toString();
    auto wrongTasks = parseJSON(validStorage);
    wrongTasks["tasks"] = JSONValue("not an array");
    invalid ~= wrongTasks.toString();

    foreach (bytes; invalid)
    {
        write(box.path, bytes);
        assertThrown!Exception(new TaskStore(box.path));
        assert(cast(string) read(box.path) == bytes);
    }

    // Constructor failures must release their advisory lock.
    write(box.path, validStorage);
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    auto snapshot = store.tasks.dup;
    write(box.path, "malformed");
    assertThrown!Exception(store.load());
    assert(store.tasks == snapshot);
    assertThrown!Exception(store.add("Do not overwrite", Priority.normal, ""));
    assertThrown!Exception(store.toggle(1));
    assert(readText(box.path) == "malformed");
    write(box.path, validStorage);
    store.load();
    store.toggle(1);
    assert(store.tasks[0].completed);
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    auto id = store.add("Original", Priority.normal, "");
    auto snapshot = store.tasks.dup;

    // Simulate an editor that does not honor the lock. Every mutation must fail
    // without changing either the caller's memory or the editor's new bytes.
    write(box.path, validStorage);
    assertThrown!Exception(store.add("Lost write", Priority.normal, ""));
    assertThrown!Exception(store.update(id, "Lost write", Priority.high, "", ""));
    assertThrown!Exception(store.toggle(id));
    assertThrown!Exception(store.remove(id));
    assert(store.tasks == snapshot);
    assert(readText(box.path) == validStorage);
    store.load();
    store.add("After reload", Priority.normal, "");
    assert(store.tasks.length == 2);
    assert(store.tasks[0].title == "Keep me");
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    auto id = store.add("Original", Priority.normal, "");
    auto snapshot = store.tasks.dup;
    auto bytes = readText(box.path);

    // O_EXCL must refuse a pre-existing temporary path, without truncating it.
    auto collision = box.path ~ ".tmp." ~ to!string(getpid()) ~ ".2";
    write(collision, "Do not touch");
    assertThrown!Exception(store.toggle(id));
    assert(readText(collision) == "Do not touch");
    assert(readText(box.path) == bytes);
    assert(store.tasks == snapshot);
    remove(collision);
    store.toggle(id);
    assert(store.tasks[0].completed);

    auto originalPath = store.path;
    store.path = box.path ~ ".other";
    assertThrown!Exception(store.toggle(id));
    assert(!exists(store.path));
    store.path = originalPath;
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto target = buildPath(box.directory, "target.json");
    write(target, validStorage);

    assert(symlink(toStringz(target), toStringz(box.path)) == 0);
    assertThrown!Exception(new TaskStore(box.path));
    assert(readText(target) == validStorage);
    remove(box.path);
    assert(link(toStringz(target), toStringz(box.path)) == 0);
    assertThrown!Exception(new TaskStore(box.path));
    remove(box.path);
    assert(mkfifo(toStringz(box.path), octal!"600") == 0);
    assertThrown!Exception(new TaskStore(box.path));
    remove(box.path);

    remove(box.path ~ ".lock");
    assert(symlink(toStringz(target), toStringz(box.path ~ ".lock")) == 0);
    assertThrown!Exception(new TaskStore(box.path));
    assert(readText(target) == validStorage);
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    write(box.path, replace(validStorage, `"id":1`, `"id":18446744073709551615`));
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    assert(store.tasks[0].id == ulong.max);
    auto bytes = readText(box.path);
    assertThrown!Exception(store.add("Overflow", Priority.normal, ""));
    assert(readText(box.path) == bytes);
    store.toggle(ulong.max);
    store.load();
    assert(store.tasks[0].id == ulong.max && store.tasks[0].completed);
}

// ---- Lock exclusion across stores and actual processes -----------------------

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();

    // POSIX open chooses the lowest free descriptor. In this single-threaded
    // test the store's lifetime lock must occupy the slot released by the probe.
    auto descriptor = open("/dev/null", O_RDONLY);
    assert(descriptor >= 0);
    assert(closeFD(descriptor) == 0);

    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    stat_t actual;
    stat_t expected;
    assert(fstat(descriptor, &actual) == 0);
    assert(stat(toStringz(box.path ~ ".lock"), &expected) == 0);
    assert(actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino);

    auto flags = fcntl(descriptor, F_GETFD);
    assert(flags >= 0 && (flags & FD_CLOEXEC) != 0);
    store.add("Lock remains close-on-exec", Priority.normal, "");
    assert(fcntl(descriptor, F_GETFD) == flags);
}

private char receive(int fd)
{
    pollfd descriptor;
    descriptor.fd = fd;
    descriptor.events = POLLIN;
    auto ready = poll(&descriptor, 1, 5000);
    assert(ready == 1 && (descriptor.revents & POLLIN), "Child process did not signal readiness");
    char value;
    assert(readFD(fd, &value, 1) == 1);
    return value;
}

private void send(int fd, char value)
{
    assert(writeFD(fd, &value, 1) == 1);
}

unittest
{
    auto box = new Sandbox;
    scope (exit) box.close();
    auto store = new TaskStore(box.path);
    scope (exit) store.close();
    store.add("Parent first", Priority.normal, "");
    assertThrown!Exception(new TaskStore(box.path));
    store.add("Parent second", Priority.high, "");
    assertThrown!Exception(new TaskStore(box.path));

    int[2] commands;
    int[2] events;
    assert(pipe(commands) == 0);
    assert(pipe(events) == 0);
    auto child = fork();
    assert(child >= 0);

    if (child == 0)
    {
        // Never unwind a child failure into the parent's inherited fixture
        // teardown. The parent observes the nonzero exit through its pipe.
        scope (exit) _exit(1);

        closeFD(commands[1]);
        closeFD(events[0]);
        store.close(); // Drop the child's inherited reference, not the parent's.

        assertThrown!Exception(new TaskStore(box.path));
        send(events[1], 'L');
        assert(receive(commands[0]) == 'R');
        auto writer = new TaskStore(box.path);
        assert(writer.tasks.length == 3);
        writer.add("Child last", Priority.low, "");
        writer.close();
        send(events[1], 'W');
        _exit(0);
    }

    closeFD(commands[0]);
    closeFD(events[1]);
    scope (exit) closeFD(commands[1]);
    scope (exit) closeFD(events[0]);

    assert(receive(events[0]) == 'L');
    store.add("Parent third", Priority.urgent, "");
    store.close();
    send(commands[1], 'R');
    assert(receive(events[0]) == 'W');
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    auto finalStore = new TaskStore(box.path);
    scope (exit) finalStore.close();
    assert(finalStore.tasks.length == 4);
    assert(finalStore.tasks[0].title == "Parent first");
    assert(finalStore.tasks[1].title == "Parent second");
    assert(finalStore.tasks[2].title == "Parent third");
    assert(finalStore.tasks[3].title == "Child last");
    assert(finalStore.tasks[3].id == 4);
}

// ---- XDG resolution without modifying the real user environment --------------

unittest
{
    auto oldHome = environment.get("HOME");
    auto oldData = environment.get("XDG_DATA_HOME");
    scope (exit)
    {
        if (oldHome is null)
            environment.remove("HOME");
        else
            environment["HOME"] = oldHome;

        if (oldData is null)
            environment.remove("XDG_DATA_HOME");
        else
            environment["XDG_DATA_HOME"] = oldData;
    }

    environment["HOME"] = "/home/test-user";
    environment["XDG_DATA_HOME"] = "/tmp/test-data";
    assert(defaultDataPath() == "/tmp/test-data/dtask/tasks.json");
    environment["XDG_DATA_HOME"] = "";
    assert(defaultDataPath() == "/home/test-user/.local/share/dtask/tasks.json");
    environment["XDG_DATA_HOME"] = "relative-is-invalid";
    assert(defaultDataPath() == "/home/test-user/.local/share/dtask/tasks.json");
    environment.remove("XDG_DATA_HOME");
    assert(defaultDataPath() == "/home/test-user/.local/share/dtask/tasks.json");
    environment.remove("HOME");
    assertThrown!Exception(defaultDataPath());
    environment["XDG_DATA_HOME"] = "/tmp/independent-data";
    assert(defaultDataPath() == "/tmp/independent-data/dtask/tasks.json");
}
