module dtask.model;

import core.stdc.errno : errno, EINTR, ENOENT, EEXIST;
import core.stdc.stdio : rename;
import core.stdc.stdlib : free;
import core.sys.posix.stdlib : realpath;
import posixFcntl = core.sys.posix.fcntl;
import core.sys.posix.fcntl : open, fcntl, F_GETFD, F_SETFD, FD_CLOEXEC,
    O_RDONLY, O_RDWR, O_CREAT, O_EXCL, O_NONBLOCK;
import core.sys.posix.sys.stat : stat_t, fstat, mkdir, fchmod, S_ISREG;
import core.sys.posix.unistd : closeFD = close, readFD = read, writeFD = write,
    fsync, unlink, getuid, getpid;
import std.algorithm : sort, canFind;
import std.array : split, join;
import std.conv : to, octal;
import std.datetime : Clock, Date;
import core.time : dur;
import std.exception : enforce, errnoEnforce;
import std.file : exists, isDir;
import std.format : format;
import std.json : JSONValue, JSONType, JSONOptions, parseJSON;
import std.path : absolutePath, buildPath, dirName, baseName, isAbsolute;
import std.process : environment;
import std.string : strip, toLower, toStringz, fromStringz;
import std.utf : validate;

/*
 * flock locks the open file description, so even two stores in one process
 * cannot accidentally become concurrent writers. The lock file is never removed.
 */
private extern(C) int flock(int fd, int operation) nothrow @nogc;
private enum lockExclusive = 2;
private enum lockNonblocking = 4;

/* ---- Task values, civil dates, and priorities -------------------------------- */

/** Persisted urgency levels; larger values sort ahead of smaller values. */
enum Priority : int
{
    low = 1,
    normal = 2,
    high = 3,
    urgent = 4
}

/** A stored task value. TaskStore validates text, IDs and civil dates before writing. */
struct Task
{
    /** Positive identifier, unique within the store and stable while the task exists. */
    ulong id;
    /** Nonblank UTF-8 title without control characters; store mutations trim its edges. */
    string title;
    /** UTF-8 notes; tabs and newlines are allowed, other control characters are not. */
    string notes;
    /** One of the four persisted urgency levels. */
    Priority priority;
    /** Canonical YYYY-MM-DD date in years 0001-9999, or empty for unscheduled work. */
    string due;
    /** Whether the task is complete; completion does not discard its due date. */
    bool completed;
    /** Local civil date of creation, preserved by updates as YYYY-MM-DD. */
    string created;
}

private Date parseDate(string value)
{
    enforce(value.length == 10 && value[4] == '-' && value[7] == '-',
        "Expected a date in YYYY-MM-DD format.");

    foreach (i, c; value)
    {
        if (i != 4 && i != 7)
            enforce(c >= '0' && c <= '9', "Invalid date digit.");
    }

    auto year = to!int(value[0 .. 4]);
    enforce(year >= 1, "Date year must be between 0001 and 9999.");

    return Date(year, to!int(value[5 .. 7]), to!int(value[8 .. 10]));
}

private string dateISO(Date date)
{
    enforce(date.year >= 1 && date.year <= 9999, "Date is outside supported years.");
    return format("%04d-%02d-%02d", date.year, date.month, date.day);
}

/** Return the current local civil date as YYYY-MM-DD (years 0001-9999). */
string todayISO()
{
    return dateISO((cast(Date) Clock.currTime()));
}

/** Resolve due-date input relative to today's local civil date; see the explicit-date overload. */
string normalizeDue(string input)
{
    return normalizeDue(input, todayISO());
}

/**
 * Resolve case-insensitive, whitespace-normalized input against a strict YYYY-MM-DD date.
 *
 * Accepts ISO dates, today/tod, tomorrow/tom, yesterday, +Nd, in N days,
 * full or three-letter weekdays (optionally prefixed by next), next week,
 * and weekend/this weekend. Weekdays and next Monday are strictly future;
 * weekend means the next Saturday, including the reference date if Saturday.
 * Empty input, none, no date and clear return an empty string.
 *
 * Returns: A canonical YYYY-MM-DD date or an empty string.
 * Throws: Exception for invalid input, an invalid reference date, or a result
 * outside years 0001-9999. Arithmetic uses civil days, not elapsed clock time.
 */
string normalizeDue(string input, string referenceDate)
{
    auto date = parseDate(referenceDate);
    auto words = split(toLower(strip(input)));
    auto value = join(words, " ");

    if (value.length == 0 || value == "none" || value == "no date" || value == "clear")
        return "";

    if (value == "today" || value == "tod")
        return dateISO(date);

    long days;
    auto weekday = cast(int) date.dayOfWeek;

    if (value == "tomorrow" || value == "tom")
        days = 1;
    else if (value == "yesterday")
        days = -1;
    else if (value == "next week")
    {
        days = (8 - weekday) % 7;

        if (days == 0)
            days = 7;
    }
    else if (value == "weekend" || value == "this weekend")
        days = (6 - weekday + 7) % 7;
    else if (value[0] == '+' || words[0] == "in")
    {
        string digits;

        if (value[0] == '+')
        {
            enforce(value.length >= 3 && value[$ - 1] == 'd',
                "Relative date must use +Nd or in N days.");
            digits = value[1 .. $ - 1];
        }
        else
        {
            enforce(words.length == 3 && words[2] == "days",
                "Relative date must use +Nd or in N days.");
            digits = words[1];
        }

        foreach (c; digits)
            enforce(c >= '0' && c <= '9', "Relative date must use +Nd or in N days.");

        /*
         * Check before multiplying so even an arbitrarily long number cannot
         * overflow or wrap into a valid date. The final cast is range checked.
         */
        ulong count;

        foreach (c; digits)
        {
            auto digit = cast(ulong) (c - '0');
            enforce(count <= (ulong.max - digit) / 10,
                "Relative date is outside supported years.");
            count = count * 10 + digit;
        }

        auto remaining = (Date(9999, 12, 31) - date).total!"days";
        enforce(count <= remaining, "Relative date is outside supported years.");
        days = cast(long) count;
    }
    else
    {
        const name = words.length == 2 && words[0] == "next" ? words[1] : value;
        static immutable names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
        int target = -1;

        foreach (i, fullName; names)
        {
            if (name == fullName || name == fullName[0 .. 3])
            {
                target = cast(int) i;
                break;
            }
        }

        if (target < 0)
            return dateISO(parseDate(value));

        /* Both bare weekdays and "next weekday" mean strictly in the future. */
        days = (target - weekday + 7) % 7;

        if (days == 0)
            days = 7;
    }

    auto earliest = (Date(1, 1, 1) - date).total!"days";
    auto latest = (Date(9999, 12, 31) - date).total!"days";
    enforce(days >= earliest && days <= latest, "Relative date is outside supported years.");
    date += dur!"days"(days);

    return dateISO(date);
}

/**
 * Return civil days from today to a canonical due date; overdue dates are negative.
 * Empty input returns int.max. Invalid nonempty dates throw an Exception.
 */
int daysUntil(string due)
{
    if (due.length == 0)
        return int.max;

    return cast(int) (parseDate(due) - (cast(Date) Clock.currTime())).total!"days";
}

/** Return the lowercase storage/UI label; throw an Exception for an invalid enum value. */
string priorityLabel(Priority priority)
{
    switch (priority)
    {
        case Priority.low: return "low";
        case Priority.normal: return "normal";
        case Priority.high: return "high";
        case Priority.urgent: return "urgent";
        default: throw new Exception("Priority must be low, normal, high, or urgent.");
    }
}

/** Parse a trimmed, case-insensitive priority name or digit 1-4; throw on other input. */
Priority parsePriority(string input)
{
    switch (toLower(strip(input)))
    {
        case "1": case "low": return Priority.low;
        case "2": case "normal": return Priority.normal;
        case "3": case "high": return Priority.high;
        case "4": case "urgent": return Priority.urgent;
        default: throw new Exception("Priority must be low, normal, high, or urgent (1-4).");
    }
}

/** Match a trimmed, case-insensitive substring in title or notes; empty queries match all. */
bool matchesTask(const Task task, string query)
{
    auto needle = toLower(strip(query));
    return canFind(toLower(task.title), needle) || canFind(toLower(task.notes), needle);
}

/**
 * Return indices into tasks without reordering or modifying the input.
 *
 * filter must be all, open, done, or today; today includes overdue unfinished
 * tasks and excludes undated tasks. query is matched by matchesTask.
 * Sort order is unfinished first, overdue first, descending priority,
 * ascending due date (undated last), then ascending ID.
 * Input tasks must have valid priorities and canonical dates.
 * Throws: Exception for an unknown filter.
 */
size_t[] sortedIndices(const(Task)[] tasks, string filter, string query)
{
    enforce(filter == "all" || filter == "open" || filter == "today" || filter == "done",
        "Unknown task filter: " ~ filter);

    auto today = todayISO();
    size_t[] indices;

    foreach (i, task; tasks)
    {
        if (!matchesTask(task, query))
            continue;

        if (filter == "open" && task.completed)
            continue;

        if (filter == "done" && !task.completed)
            continue;

        /* Today includes overdue work, but excludes completed and undated tasks. */
        if (filter == "today" && (task.completed || task.due.length == 0 || task.due > today))
            continue;

        indices ~= i;
    }

    /* Lexicographic rank: (done, not-overdue, -priority, due-or-infinity, id). */
    sort!((a, b) {
        const left = tasks[a];
        const right = tasks[b];

        if (left.completed != right.completed)
            return !left.completed;

        const leftOverdue = left.due.length != 0 && left.due < today;
        const rightOverdue = right.due.length != 0 && right.due < today;

        if (leftOverdue != rightOverdue)
            return leftOverdue;

        if (left.priority != right.priority)
            return left.priority > right.priority;

        if (left.due != right.due)
        {
            if (left.due.length == 0)
                return false;

            if (right.due.length == 0)
                return true;

            return left.due < right.due;
        }

        return left.id < right.id;
    })(indices);

    return indices;
}

/**
 * Resolve tasks.json under absolute XDG_DATA_HOME, or HOME/.local/share.
 * Relative XDG values are ignored; a required missing/relative HOME throws.
 * Does not create directories or access task storage.
 */
string defaultDataPath()
{
    auto root = environment.get("XDG_DATA_HOME", "");

    /* XDG specifies absolute paths. Relative values are treated as unset. */
    if (root.length == 0 || !isAbsolute(root))
    {
        auto home = environment.get("HOME", "");
        enforce(home.length != 0 && isAbsolute(home), "HOME must be an absolute path.");
        root = buildPath(home, ".local", "share");
    }

    return buildPath(root, "dtask", "tasks.json");
}

/*
 * ---- Strict storage schema ---------------------------------------------------
 * Version 1: {"version": 1, "tasks": [{id,title,notes,priority,due,completed,created}]}.
 * Dates on disk are canonical ISO dates; relative dates are input syntax only.
 */

private void validateText(string text, bool multiline)
{
    validate(text);

    foreach (dchar c; text)
    {
        if (multiline && (c == '\n' || c == '\t'))
            continue;

        enforce(c >= 0x20 && !(c >= 0x7f && c <= 0x9f),
            "Task text contains a control character.");
    }
}

private void validateTask(const Task task)
{
    enforce(task.id != 0, "Task IDs must be positive.");
    validateText(task.title, false);
    enforce(strip(task.title).length != 0, "Task title cannot be empty.");
    validateText(task.notes, true);
    priorityLabel(task.priority);

    if (task.due.length != 0)
        parseDate(task.due);

    parseDate(task.created);
}

private void validateTasks(const(Task)[] tasks)
{
    bool[ulong] ids;

    foreach (task; tasks)
    {
        validateTask(task);
        enforce((task.id in ids) is null, "Duplicate task ID.");
        ids[task.id] = true;
    }
}

private ulong unsignedInteger(JSONValue value)
{
    if (value.type == JSONType.uinteger)
        return value.uinteger;

    enforce(value.type == JSONType.integer && value.integer >= 0,
        "Expected a nonnegative JSON integer.");

    return cast(ulong) value.integer;
}

private void requireFields(JSONValue value, string[] fields)
{
    enforce(value.type == JSONType.object, "Expected a JSON object.");
    auto members = value.orderedObjectNoRef;
    enforce(members.length == fields.length, "Unexpected or missing JSON fields.");
    bool[string] seen;

    foreach (member; members)
    {
        enforce(canFind(fields, member.key), "Unknown JSON field: " ~ member.key);
        enforce((member.key in seen) is null, "Duplicate JSON field: " ~ member.key);
        seen[member.key] = true;
    }
}

private Task[] decodeTasks(string text)
{
    validate(text);
    auto root = parseJSON(text, 8, JSONOptions.strictParsing | JSONOptions.preserveObjectOrder);
    requireFields(root, ["version", "tasks"]);
    enforce(unsignedInteger(root["version"]) == 1, "Unsupported task storage version.");
    enforce(root["tasks"].type == JSONType.array, "Tasks must be a JSON array.");

    Task[] result;

    foreach (value; root["tasks"].array)
    {
        requireFields(value, ["id", "title", "notes", "priority", "due", "completed", "created"]);
        auto priority = unsignedInteger(value["priority"]);
        enforce(priority >= 1 && priority <= 4, "Priority must be between 1 and 4.");
        enforce(value["completed"].type == JSONType.true_ || value["completed"].type == JSONType.false_,
            "Completed must be a JSON boolean.");

        result ~= Task(unsignedInteger(value["id"]), value["title"].str,
            value["notes"].str, cast(Priority) priority, value["due"].str,
            value["completed"].type == JSONType.true_, value["created"].str);
    }

    validateTasks(result);
    return result;
}

private string encodeTasks(const(Task)[] tasks)
{
    JSONValue[] values;

    foreach (task; tasks)
    {
        values ~= JSONValue([
            "id": JSONValue(task.id),
            "title": JSONValue(task.title),
            "notes": JSONValue(task.notes),
            "priority": JSONValue(cast(int) task.priority),
            "due": JSONValue(task.due),
            "completed": JSONValue(task.completed),
            "created": JSONValue(task.created)
        ]);
    }

    return JSONValue(["version": JSONValue(1), "tasks": JSONValue(values)]).toPrettyString() ~ "\n";
}

/* ---- POSIX ownership and atomic persistence ---------------------------------- */

/*
 * Use the native open flags even where this druntime omits their declarations.
 * These ABI constants come from FreeBSD 14's sys/sys/fcntl.h and Darwin's
 * bsd/sys/fcntl.h. Keep both atomic close-on-exec and kernel symlink rejection.
 */
version (FreeBSD)
{
    /* LDC 1.43's druntime has no core.sys.freebsd.sys.fcntl module. */
    private enum O_NOFOLLOW = 0x0100;
    private enum closeOnExecFlag = 0x00100000;
}
else version (OSX)
{
    import core.sys.darwin.fcntl : O_NOFOLLOW;

    private enum closeOnExecFlag = 0x01000000;
}
else
{
    import core.sys.posix.fcntl : O_NOFOLLOW;

    static if (__traits(hasMember, posixFcntl, "O_CLOEXEC"))
        private enum closeOnExecFlag = posixFcntl.O_CLOEXEC;
    else
        private enum closeOnExecFlag = 0;
}

private void setCloseOnExec(int fd)
{
    auto flags = fcntl(fd, F_GETFD);
    errnoEnforce(flags >= 0, "Cannot read task descriptor flags");
    errnoEnforce(fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0,
        "Cannot set task descriptor close-on-exec");
}

private void ensureDirectory(string directory)
{
    if (exists(directory))
    {
        enforce(isDir(directory), "Storage parent is not a directory.");
        return;
    }

    auto parent = dirName(directory);

    if (parent != directory)
        ensureDirectory(parent);

    if (mkdir(toStringz(directory), octal!"700") != 0)
        errnoEnforce(errno == EEXIST && isDir(directory), "Cannot create task directory");
}

private void requireRegularFile(int fd)
{
    stat_t info;
    errnoEnforce(fstat(fd, &info) == 0, "Cannot inspect task file");
    enforce(S_ISREG(info.st_mode), "Task storage must be a regular file.");
    enforce(info.st_uid == getuid() && info.st_nlink == 1,
        "Task storage must be owned by this user and have no hard links.");
}

private string readStorage(string path, out bool present)
{
    auto fd = open(toStringz(path), O_RDONLY | closeOnExecFlag | O_NOFOLLOW | O_NONBLOCK);

    if (fd < 0 && errno == ENOENT)
    {
        present = false;
        return "";
    }

    errnoEnforce(fd >= 0, "Cannot open task storage");
    scope (exit) closeFD(fd);
    setCloseOnExec(fd);
    requireRegularFile(fd);
    present = true;
    char[] bytes;
    char[8192] buffer;

    while (true)
    {
        auto count = readFD(fd, buffer.ptr, buffer.length);

        if (count < 0 && errno == EINTR)
            continue;

        errnoEnforce(count >= 0, "Cannot read task storage");

        if (count == 0)
            break;

        bytes ~= buffer[0 .. cast(size_t) count];
    }

    return bytes.idup;
}

/**
 * Single-writer JSON store with validated, atomic replacement on each mutation.
 *
 * Owns a nonblocking advisory lock until close; callers should use scope(exit)
 * rather than rely on finalization. Files must be regular, singly linked and
 * owned by the current user; symlink storage and lock files are rejected.
 * Mutations detect external byte changes and require a successful load before
 * retrying. Validation and pre-commit failures leave the in-memory tasks intact.
 * If directory sync fails after rename, disk may already contain the commit;
 * reload to reconcile it. Instances are not synchronized for concurrent threads.
 */
final class TaskStore
{
    /**
     * Current in-memory values. Direct edits are not automatically persisted;
     * use the mutation methods, which validate the complete candidate collection.
     */
    public Task[] tasks;
    /** Resolved storage path. Changing it while open makes load/mutations fail. */
    public string path;

    private int lockFD = -1;
    private string lockedPath;
    private string loadedBytes;
    private bool loaded;
    private bool hadFile;
    private ulong temporaryCounter;

    /**
     * Create missing parent directories with mode 0700, acquire the 0600 lock,
     * and load the store. Existing parent permissions are preserved.
     * Throws on invalid paths, unsafe files, lock contention, or invalid storage.
     */
    this(string path)
    {
        enforce(path.length != 0 && !canFind(path, '\0'), "Invalid task storage path.");
        auto absolute = absolutePath(path);
        ensureDirectory(dirName(absolute));
        auto resolved = realpath(toStringz(dirName(absolute)), null);
        errnoEnforce(resolved !is null, "Cannot resolve task directory");
        scope (exit) free(resolved);
        this.path = buildPath(fromStringz(resolved).idup, baseName(absolute));
        lockedPath = this.path;

        lockFD = open(toStringz(lockedPath ~ ".lock"),
            O_RDWR | O_CREAT | closeOnExecFlag | O_NOFOLLOW | O_NONBLOCK, octal!"600");
        errnoEnforce(lockFD >= 0, "Cannot open task lock");
        scope (failure) close();

        setCloseOnExec(lockFD);
        requireRegularFile(lockFD);
        errnoEnforce(flock(lockFD, lockExclusive | lockNonblocking) == 0,
            "Task storage is locked by another writer");
        errnoEnforce(fchmod(lockFD, octal!"600") == 0, "Cannot secure task lock");
        load();
    }

    ~this()
    {
        close();
    }

    /**
     * Release the writer lock without saving direct edits. Safe to call repeatedly;
     * subsequent loads and mutations fail and a new instance is needed to reopen.
     */
    void close() nothrow
    {
        if (lockFD >= 0)
        {
            closeFD(lockFD);
            lockFD = -1;
        }

        loaded = false;
    }

    private void requireOpen()
    {
        enforce(lockFD >= 0, "Task store is closed.");
        enforce(path == lockedPath, "Cannot change the path of an open task store.");
    }

    /**
     * Replace tasks from validated version-1 JSON; a missing file yields no tasks.
     * On failure, retain the previous tasks but block mutations until a successful load.
     */
    void load()
    {
        requireOpen();
        loaded = false;
        bool present;
        auto bytes = readStorage(lockedPath, present);
        auto candidate = present ? decodeTasks(bytes) : null;

        tasks = candidate;
        loadedBytes = bytes;
        hadFile = present;
        loaded = true;
    }

    /**
     * Persist a new unfinished task and return one greater than the largest current ID.
     * Trim title, normalize due, and use today's creation date; invalid values or
     * exhausted IDs throw. Deleted IDs may be reused when they were the largest.
     */
    ulong add(string title, Priority priority, string due, string notes = "")
    {
        validateText(title, false);
        ulong highest;

        foreach (task; tasks)
        {
            if (task.id > highest)
                highest = task.id;
        }

        enforce(highest != ulong.max, "No task IDs remain available.");
        auto candidate = tasks.dup;
        auto id = highest + 1;
        candidate ~= Task(id, strip(title), notes, priority, normalizeDue(due), false, todayISO());
        persist(candidate);

        return id;
    }

    /**
     * Persist edited fields, trimming title and normalizing due while preserving
     * completion and creation date. Invalid values or an unknown ID throw.
     */
    void update(ulong id, string title, Priority priority, string due, string notes)
    {
        validateText(title, false);
        auto index = findTask(id);
        auto candidate = tasks.dup;
        candidate[index].title = strip(title);
        candidate[index].priority = priority;
        candidate[index].due = normalizeDue(due);
        candidate[index].notes = notes;
        persist(candidate);
    }

    /** Persist the inverse completion state of an existing ID; throw if it is absent. */
    void toggle(ulong id)
    {
        auto index = findTask(id);
        auto candidate = tasks.dup;
        candidate[index].completed = !candidate[index].completed;
        persist(candidate);
    }

    /** Permanently persist removal of an existing ID; throw if it is absent. */
    void remove(ulong id)
    {
        auto index = findTask(id);
        auto candidate = tasks[0 .. index] ~ tasks[index + 1 .. $];
        persist(candidate);
    }

    private size_t findTask(ulong id)
    {
        foreach (i, task; tasks)
        {
            if (task.id == id)
                return i;
        }

        throw new Exception("Task ID not found: " ~ to!string(id));
    }

    private void persist(Task[] candidate)
    {
        requireOpen();
        enforce(loaded, "Load valid storage before making changes.");
        validateTasks(candidate);

        /* A noncooperating editor must not cause silent lost writes either. */
        bool present;
        auto current = readStorage(lockedPath, present);
        enforce(present == hadFile && current == loadedBytes,
            "Task storage changed outside this store; reload before writing.");
        auto bytes = encodeTasks(candidate);
        auto directoryFD = open(toStringz(dirName(lockedPath)), O_RDONLY | closeOnExecFlag);
        errnoEnforce(directoryFD >= 0, "Cannot open task directory");
        scope (exit) closeFD(directoryFD);
        setCloseOnExec(directoryFD);

        /* Fail before changing anything on filesystems without directory syncing. */
        errnoEnforce(fsync(directoryFD) == 0, "Cannot sync task directory");
        auto temporary = lockedPath ~ ".tmp." ~ to!string(getpid()) ~ "." ~ to!string(++temporaryCounter);
        auto fd = open(toStringz(temporary), O_RDWR | O_CREAT | O_EXCL | closeOnExecFlag | O_NOFOLLOW, octal!"600");
        errnoEnforce(fd >= 0, "Cannot create temporary task file");
        scope (exit)
        {
            if (fd >= 0)
                closeFD(fd);

            unlink(toStringz(temporary));
        }

        setCloseOnExec(fd);
        size_t offset;

        while (offset < bytes.length)
        {
            auto count = writeFD(fd, bytes.ptr + offset, bytes.length - offset);

            if (count < 0 && errno == EINTR)
                continue;

            errnoEnforce(count > 0, "Cannot write task storage");
            offset += count;
        }

        errnoEnforce(fsync(fd) == 0, "Cannot sync task storage");
        auto closed = closeFD(fd);
        fd = -1;
        errnoEnforce(closed == 0, "Cannot close task storage");
        errnoEnforce(rename(toStringz(temporary), toStringz(lockedPath)) == 0,
            "Cannot replace task storage");
        errnoEnforce(fsync(directoryFD) == 0, "Cannot sync committed task directory; reload storage");

        tasks = candidate;
        loadedBytes = bytes;
        hadFile = true;
    }
}
