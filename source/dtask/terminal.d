module dtask.terminal;

import core.stdc.errno : errno, EINTR;
import core.stdc.stdlib : atexit;
import core.sys.posix.poll : poll, pollfd, POLLIN, POLLERR, POLLHUP, POLLNVAL;
import core.sys.posix.signal;
import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
import core.sys.posix.termios;
import core.sys.posix.unistd : isatty, read, posixWrite = write, _exit;
import core.time : MonoTime, dur;
import dtask.text : fitText, graphemePrefixBytes;
import std.exception : enforce;
import std.utf : encode;

/** Event discriminator; none means no actionable input, interrupt requests shutdown. */
enum Key
{
    none, text, escape, enter, backspace, tab, up, down, left, right,
    home, end, pageUp, pageDown, deleteKey, interrupt, mouse, resize
}

/** Decoded input or resize notification. Only fields associated with key are meaningful. */
struct Event
{
    /** Determines whether to read text, mouse coordinates, or no payload. */
    Key key;
    /** UTF-8 for Key.text, including whole bracketed pastes; unpasted Ctrl-U is "\x15". */
    string text;
    /** One-based terminal column for Key.mouse. */
    int x;
    /** One-based terminal row for Key.mouse. */
    int y;
    /** Raw SGR mouse code, retaining button, modifier, motion and wheel bits. */
    int button;
    /** True for an SGR mouse release report, false for press/wheel reports. */
    bool release;
    /** Whether the mouse code has the motion bit set; independent of release. */
    bool motion;
    /** True for bracketed clipboard text, which must never execute navigation commands. */
    bool pasted;
}

/**
 * Incremental byte decoder independent of file descriptors and clocks.
 * Callers explicitly expire a lone Escape; incomplete control sequences remain
 * quarantined until their terminator, even after exceeding the size limit.
 */
struct InputDecoder
{
    /** Maximum buffered CSI/SS3 parameter bytes; longer sequences are discarded. */
    enum maxSequence = 128;
    /** Maximum UTF-8 paste bytes; excess input is discarded without splitting a cluster. */
    enum maxPaste = 65_536;

    private enum State { ground, escape, intermediate, csi, ss3, controlString, stringEscape, legacyMouse }
    private State state;
    private char[maxSequence] sequence;
    private size_t sequenceLength;
    private bool overflow;
    private bool pasting;
    private bool pasteFull;
    private bool oscString;
    private uint stringRemaining;
    private bool stringC1;
    private char[] paste;
    private uint scalar;
    private uint minimum;
    private uint remaining;

    /** Whether an unpasted lone Escape is pending and may be expired by the caller. */
    @property bool waitingForEscape() const
    {
        return state == State.escape && !pasting;
    }

    /**
     * Emit Key.escape and clear a pending lone Escape; otherwise return Key.none.
     * Does not flush partial UTF-8, paste data, or incomplete control sequences.
     */
    Event expireEscape()
    {
        if (!waitingForEscape)
            return Event.init;

        state = State.ground;
        return Event(Key.escape);
    }

    private Event textEvent(dchar value)
    {
        /* Encoded C1 introducers have the same quarantine rules as ESC forms. */
        if (value == 0x9b)
        {
            beginSequence(State.csi);
            return Event.init;
        }

        if (value == 0x9d || value == 0x90 || value == 0x98 || value == 0x9e || value == 0x9f)
        {
            state = State.controlString;
            oscString = value == 0x9d;
            return Event.init;
        }

        /* Paste payloads may retain paragraph breaks and tabs, but no other controls. */
        const pasteWhitespace = pasting && (value == '\r' || value == '\n' || value == '\t');
        if ((value < 0x20 && !pasteWhitespace) || (value >= 0x7f && value <= 0x9f))
            return Event.init;

        char[4] bytes;
        size_t count = encode(bytes, value);

        if (pasting)
        {
            if (!pasteFull)
            {
                paste ~= bytes[0 .. count];

                if (paste.length > maxPaste)
                {
                    /*
                     * One overflowing scalar (at most four bytes) reveals a
                     * continuation of the final cluster. Segment once, then
                     * discard the tail while preserving control quarantine.
                     */
                    paste.length = graphemePrefixBytes(cast(string) paste, maxPaste);
                    pasteFull = true;
                }
            }

            return Event.init;
        }

        return Event(Key.text, bytes[0 .. count].idup);
    }

    private void beginSequence(State next)
    {
        state = next;
        sequenceLength = 0;
        overflow = false;
    }

    private Event finishSequence(ubyte finalByte)
    {
        state = State.ground;

        if (overflow)
            return Event.init;

        auto parameters = sequence[0 .. sequenceLength];

        /*
         * Old X10 mouse reports carry three bytes after CSI M. We do not
         * enable this mode, but a stale report must not become editable text.
         */
        if (finalByte == 'M' && parameters.length == 0)
        {
            state = State.legacyMouse;
            sequenceLength = 0;
            return Event.init;
        }

        if (finalByte == '~' && parameters == "201")
        {
            if (!pasting)
                return Event.init;

            pasting = false;
            auto result = paste.idup;
            paste.length = 0;

            if (result.length == 0)
                return Event.init;

            auto event = Event(Key.text, result);
            event.pasted = true;
            return event;
        }

        if (pasting)
            return Event.init;

        if (finalByte == '~' && parameters == "200")
        {
            pasting = true;
            pasteFull = false;
            paste.length = 0;
            return Event.init;
        }

        if (parameters.length && parameters[0] == '<')
        {
            if (finalByte != 'M' && finalByte != 'm')
                return Event.init;

            int[3] values;
            if (!parseNumbers(parameters[1 .. $], values[]) || values[1] < 1 || values[2] < 1)
                return Event.init;

            /*
             * Preserve the complete SGR button code: its low bits identify the
             * button, while modifiers, motion and wheel reports occupy other bits.
             */
            return Event(Key.mouse, "", values[1], values[2], values[0],
                finalByte == 'm', (values[0] & 32) != 0);
        }

        /* Recognize only numeric key parameters, not private/intermediate CSI. */
        foreach (character; parameters)
        {
            if ((character < '0' || character > '9') && character != ';')
                return Event.init;
        }

        switch (finalByte)
        {
            case 'A': return Event(Key.up);
            case 'B': return Event(Key.down);
            case 'C': return Event(Key.right);
            case 'D': return Event(Key.left);
            case 'H': return Event(Key.home);
            case 'F': return Event(Key.end);
            case 'Z': return Event(Key.tab);
            case '~':
                size_t separator;
                while (separator < parameters.length && parameters[separator] != ';')
                    ++separator;

                const number = parameters[0 .. separator];
                if (number == "1" || number == "7") return Event(Key.home);
                if (number == "4" || number == "8") return Event(Key.end);
                if (number == "3") return Event(Key.deleteKey);
                if (number == "5") return Event(Key.pageUp);
                if (number == "6") return Event(Key.pageDown);
                return Event.init;
            default:
                return Event.init;
        }
    }

    private static bool parseNumbers(const(char)[] text, int[] output)
    {
        size_t field;
        bool digit;

        foreach (character; text)
        {
            if (character == ';')
            {
                if (!digit || ++field >= output.length)
                    return false;

                digit = false;
                continue;
            }

            if (character < '0' || character > '9')
                return false;

            const value = character - '0';
            if (output[field] > (int.max - value) / 10)
                return false;

            output[field] = output[field] * 10 + value;
            digit = true;
        }

        return digit && field + 1 == output.length;
    }

    /**
     * Consume one byte and return at most one event; Key.none means no completed event.
     * Text is decoded as UTF-8; control sequences are consumed rather than exposed.
     * Bracketed paste emits one marked, bounded text event preserving CR/LF/tab.
     * Unpasted Ctrl-C resets the decoder and emits Key.interrupt.
     */
    Event feed(ubyte value)
    {
        /*
         * Ctrl-C remains actionable in a broken sequence, but pasted control
         * bytes never turn into application commands.
         */
        if (value == 3 && !pasting)
        {
            this = InputDecoder.init;
            return Event(Key.interrupt);
        }

        if (state == State.legacyMouse)
        {
            if (++sequenceLength == 3)
                state = State.ground;

            return Event.init;
        }

        if (state == State.controlString || state == State.stringEscape)
        {
            /* A UTF-8 continuation byte equal to ST (0x9c) is not itself ST. */
            bool terminator;
            if (stringRemaining && (value & 0xc0) == 0x80)
            {
                --stringRemaining;
                terminator = stringC1 && stringRemaining == 0 && value == 0x9c;
            }
            else
            {
                stringRemaining = 0;
                terminator = value == 0x9c;
                stringC1 = value == 0xc2;

                if (value >= 0xc2 && value <= 0xdf)
                    stringRemaining = 1;
                else if (value >= 0xe0 && value <= 0xef)
                    stringRemaining = 2;
                else if (value >= 0xf0 && value <= 0xf4)
                    stringRemaining = 3;
            }

            if ((oscString && value == 7) || terminator ||
                (state == State.stringEscape && value == '\\'))
            {
                state = State.ground;
                stringRemaining = 0;
            }
            else
                state = value == 0x1b ? State.stringEscape : State.controlString;

            return Event.init;
        }

        if (state == State.escape)
        {
            switch (value)
            {
                case '[': beginSequence(State.csi); break;
                case 'O': beginSequence(State.ss3); break;
                case ']': case 'P': case 'X': case '^': case '_':
                    state = State.controlString;
                    oscString = value == ']';
                    break;
                case 0x1b: break;
                default:
                    state = value >= 0x20 && value <= 0x2f ? State.intermediate : State.ground;
                    break;
            }

            return Event.init;
        }

        if (state == State.intermediate)
        {
            if (value >= 0x30 && value <= 0x7e)
                state = State.ground;
            else if (value == 0x1b)
                state = State.escape;

            return Event.init;
        }

        if (state == State.csi || state == State.ss3)
        {
            if (value == 0x1b)
            {
                state = State.escape;
                return Event.init;
            }

            if (value >= 0x40 && value <= 0x7e)
                return finishSequence(value);

            if (value < 0x20 || value > 0x3f)
                overflow = true;
            else if (sequenceLength < sequence.length)
                sequence[sequenceLength++] = cast(char) value;
            else
                overflow = true;

            return Event.init;
        }

        if (remaining)
        {
            if ((value & 0xc0) != 0x80)
            {
                remaining = 0;
                return feed(value);
            }

            scalar = (scalar << 6) | (value & 0x3f);
            if (--remaining)
                return Event.init;

            if (scalar < minimum || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff))
                return textEvent('\ufffd');

            return textEvent(cast(dchar) scalar);
        }

        if (value == 0x1b)
        {
            state = State.escape;
            return Event.init;
        }

        /* Some terminals send raw 8-bit CSI/OSC. Do not expose their payload. */
        if (value >= 0x80 && value <= 0x9f)
            return textEvent(value);

        if (value < 0x20 || value == 0x7f)
        {
            if (pasting)
                return value == '\r' || value == '\n' || value == '\t'
                    ? textEvent(value) : Event.init;

            switch (value)
            {
                case '\r': case '\n': return Event(Key.enter);
                case 0x7f: case 8: return Event(Key.backspace);
                case '\t': return Event(Key.tab);
                /* The UI consumes Ctrl-U as a clear-field command, not text. */
                case 0x15: return Event(Key.text, "\x15");
                default: return Event.init;
            }
        }

        if (value < 0x7f)
            return textEvent(value);

        if (value >= 0xc2 && value <= 0xdf)
        {
            scalar = value & 0x1f;
            minimum = 0x80;
            remaining = 1;
        }
        else if (value >= 0xe0 && value <= 0xef)
        {
            scalar = value & 0x0f;
            minimum = 0x800;
            remaining = 2;
        }
        else if (value >= 0xf0 && value <= 0xf4)
        {
            scalar = value & 7;
            minimum = 0x10000;
            remaining = 3;
        }
        else if (value >= 0xa0)
            return textEvent('\ufffd');

        return Event.init;
    }
}

/*
 * Keep the render budget independent of decoder progress. Escape has its own
 * precise monotonic deadline, retained across short readEvent calls. This
 * package boundary lets tests use synthetic time without replacing POSIX I/O.
 */
package struct InputTiming
{
    private InputDecoder decoder;
    private MonoTime visualDeadline;
    private MonoTime escapeDeadline;

    void beginWait(int milliseconds, MonoTime now)
    {
        visualDeadline = now + dur!"msecs"(milliseconds);
    }

    bool renderDue(MonoTime now) const
    {
        return now >= visualDeadline;
    }

    int waitMillis(MonoTime now) const
    {
        MonoTime deadline = visualDeadline;
        if (decoder.waitingForEscape && escapeDeadline < deadline)
            deadline = escapeDeadline;

        if (now >= deadline)
            return 0;

        /* Round up so sub-millisecond remnants cannot expire Escape early. */
        const remaining = (deadline - now).total!"nsecs";
        return cast(int) ((remaining + 999_999) / 1_000_000);
    }

    Event expireEscape(MonoTime now)
    {
        if (!decoder.waitingForEscape || now < escapeDeadline)
            return Event.init;

        return decoder.expireEscape();
    }

    Event feed(ubyte value, MonoTime now)
    {
        auto event = decoder.feed(value);
        if (decoder.waitingForEscape)
            escapeDeadline = now + dur!"msecs"(35);

        return event;
    }
}

/**
 * Sanitize text and clip/pad it to exactly width terminal cells; nonpositive widths return empty.
 *
 * Uses the shared stored-text sanitizer and modern grapheme cell widths.
 * CR, LF and tabs become spaces. Clipping stops at the first non-fitting cluster,
 * dropping leading mark-only clusters. Stored text has no keyboard paste cap.
 * Width lookup uses a private thread locale and leaves the process locale unchanged.
 * Throws: Exception if a character-width locale cannot be created or selected.
 */
string fit(string text, int width)
{
    return fitText(text, width);
}

/*
 * The terminal is a process-wide resource. Saved state is plain native data:
 * handlers touch no class, GC allocation, exception, lock or D runtime service.
 * POSIX specifies write, tcsetattr and _exit as async-signal-safe. SIGKILL and
 * SIGSTOP cannot be intercepted by any application.
 * Button-event mode reports motion only while a button is held. All cleanup
 * paths, including signal handlers, disable it along with SGR encoding.
 */
private enum enterScreen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h";
private enum leaveScreen = "\x1b[?2026l\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l";
private immutable watchedSignals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE];
private __gshared termios savedAttributes;
private __gshared sigaction_t[5] savedHandlers;
private __gshared size_t installedHandlers;
private __gshared sig_atomic_t ownsTerminal;
private __gshared bool exitRegistered;

private int writeBytes(string text) nothrow @nogc
{
    size_t offset;
    while (offset < text.length)
    {
        const count = posixWrite(1, text.ptr + offset, text.length - offset);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;

        offset += count;
    }

    return 0;
}

private int restoreAttributes() nothrow @nogc
{
    int result;
    do
        result = tcsetattr(0, TCSANOW, &savedAttributes);
    while (result < 0 && errno == EINTR);

    return result;
}

private extern (C) void terminationHandler(int signalNumber) nothrow @nogc
{
    if (ownsTerminal)
    {
        const attributesRestored = restoreAttributes() == 0;
        const screenRestored = writeBytes(leaveScreen) == 0;

        /*
         * Attempt both cleanup operations even when the first fails. A cleanup
         * failure gets a nonzero status distinct from normal signal shutdown.
         */
        if (!attributesRestored || !screenRestored)
        {
            _exit(1);
        }
    }

    _exit(128 + signalNumber);
}

private sigset_t signalMask() nothrow @nogc
{
    sigset_t mask;
    sigemptyset(&mask);
    foreach (number; watchedSignals)
        sigaddset(&mask, number);

    return mask;
}

private int releaseTerminal() nothrow @nogc
{
    if (!ownsTerminal)
        return 0;

    auto mask = signalMask();
    sigset_t previous;
    if (sigprocmask(SIG_BLOCK, &mask, &previous) < 0)
        return -1;

    int result = restoreAttributes();
    if (writeBytes(leaveScreen) < 0)
        result = -1;

    while (installedHandlers)
    {
        --installedHandlers;
        if (sigaction(watchedSignals[installedHandlers], &savedHandlers[installedHandlers], null) < 0)
            result = -1;
    }

    ownsTerminal = 0;
    if (sigprocmask(SIG_SETMASK, &previous, null) < 0)
        result = -1;

    return result;
}

private extern (C) void exitCleanup() nothrow @nogc
{
    /*
     * atexit cannot return an error to main, but cleanup failures must still
     * be visible to the invoking shell rather than silently reporting success.
     */
    if (releaseTerminal() != 0)
    {
        _exit(1);
    }
}

/**
 * Exclusive process-wide owner of stdin/stdout TTY state and the alternate screen.
 * Use scope(exit) close() for deterministic restoration. Exit and termination-signal
 * handlers provide fallback cleanup; SIGKILL and SIGSTOP cannot be intercepted.
 */
final class Terminal
{
    private bool open;
    private InputTiming input;
    private int lastColumns;
    private int lastRows;

    /**
     * Acquire TTY ownership, enter raw mode, and enable SGR button-motion mouse
     * reporting and bracketed paste. Throws for non-TTY descriptors, an existing
     * owner, or setup failure; partial setup is restored before propagating failure.
     */
    this()
    {
        enforce(!ownsTerminal, "A terminal is already owned by this process");
        enforce(isatty(0) == 1 && isatty(1) == 1, "dtask requires a TTY on standard input and output");
        enforce(tcgetattr(0, &savedAttributes) == 0, "Cannot read terminal attributes");

        if (!exitRegistered)
        {
            enforce(atexit(&exitCleanup) == 0, "Cannot register terminal cleanup");
            exitRegistered = true;
        }

        auto mask = signalMask();
        sigset_t previous;
        enforce(sigprocmask(SIG_BLOCK, &mask, &previous) == 0, "Cannot block terminal signals");
        scope (exit)
        {
            enforce(sigprocmask(SIG_SETMASK, &previous, null) == 0,
                "Cannot restore terminal signal mask");
        }

        ownsTerminal = 1;
        scope (failure)
        {
            /*
             * If initialization fails, restore the terminal before propagating
             * the original error. Failed restoration cannot report success.
             */
            if (releaseTerminal() != 0)
            {
                _exit(1);
            }
        }

        sigaction_t action;
        action.sa_handler = &terminationHandler;
        action.sa_mask = mask;
        action.sa_flags = 0;

        foreach (number; watchedSignals)
        {
            enforce(sigaction(number, &action, &savedHandlers[installedHandlers]) == 0,
                "Cannot install terminal signal handler");
            ++installedHandlers;
        }

        auto raw = savedAttributes;
        raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON | INLCR | IGNCR | PARMRK);
        raw.c_oflag &= ~OPOST;
        raw.c_cflag = (raw.c_cflag & ~(CSIZE | PARENB)) | CS8;
        raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;

        enforce(tcsetattr(0, TCSANOW, &raw) == 0, "Cannot enable raw terminal mode");
        enforce(writeBytes(enterScreen) == 0, "Cannot enter alternate screen");
        open = true;
        size(lastColumns, lastRows);
    }

    /**
     * Restore terminal attributes, screen modes and signal handlers; repeated calls
     * are harmless. Throws if restoration fails. This instance cannot be reopened.
     */
    void close()
    {
        if (!open)
            return;

        open = false;
        enforce(releaseTerminal() == 0, "Cannot restore terminal state");
    }

    /**
     * Write trusted rendering bytes, including intentional ANSI commands.
     * Pass editable/stored text through fit first. Throws if closed or output fails.
     */
    void write(string text)
    {
        enforce(open, "Terminal is closed");
        enforce(writeBytes(text) == 0, "Cannot write to terminal");
    }

    /**
     * Read terminal dimensions; zero dimensions fall back independently to 80x24.
     * Throws if closed or the dimension query fails.
     */
    void size(out int columns, out int rows)
    {
        enforce(open, "Terminal is closed");
        winsize dimensions;
        enforce(ioctl(1, TIOCGWINSZ, &dimensions) == 0, "Cannot read terminal dimensions");
        columns = dimensions.ws_col ? dimensions.ws_col : 80;
        rows = dimensions.ws_row ? dimensions.ws_row : 24;
    }

    /**
     * Wait at most waitMilliseconds for input or a size change; may return Key.none.
     * The nonnegative render budget is capped at 100 ms for resize responsiveness.
     * A lone Escape keeps its separate 35 ms grace period across calls. Partial
     * UTF-8, control sequences and paste survive render deadlines unchanged.
     * EOF, hangup or decoded Ctrl-C closes the terminal and returns Key.interrupt.
     * Throws if closed or terminal I/O fails. Resize events carry no size payload.
     */
    Event readEvent(int waitMilliseconds = 100)
    {
        enforce(open, "Terminal is closed");
        enforce(waitMilliseconds >= 0, "Terminal wait must be nonnegative");

        input.beginWait(waitMilliseconds < 100 ? waitMilliseconds : 100, MonoTime.currTime);
        bool attemptedPoll;

        for (;;)
        {
            int columns, rows;
            size(columns, rows);
            if (columns != lastColumns || rows != lastRows)
            {
                lastColumns = columns;
                lastRows = rows;
                return Event(Key.resize);
            }

            const now = MonoTime.currTime;
            if (attemptedPoll && input.renderDue(now))
                return input.expireEscape(now);

            pollfd descriptor;
            descriptor.fd = 0;
            descriptor.events = POLLIN;
            const ready = poll(&descriptor, 1, input.waitMillis(now));
            attemptedPoll = true;
            if (ready < 0 && errno == EINTR)
                continue;

            enforce(ready >= 0, "Cannot poll terminal input");
            if (ready == 0)
            {
                const afterPoll = MonoTime.currTime;
                auto event = input.expireEscape(afterPoll);
                if (event.key != Key.none || input.renderDue(afterPoll))
                    return event;

                continue;
            }

            enforce(!(descriptor.revents & (POLLERR | POLLNVAL)), "Terminal input failed");
            if (!(descriptor.revents & POLLIN) && (descriptor.revents & POLLHUP))
            {
                close();
                return Event(Key.interrupt);
            }

            ubyte value;
            auto count = read(0, &value, 1);
            if (count < 0 && errno == EINTR)
                continue;

            enforce(count >= 0, "Cannot read terminal input");
            if (count == 0)
            {
                close();
                return Event(Key.interrupt);
            }

            auto event = input.feed(value, MonoTime.currTime);
            if (event.key == Key.interrupt)
                close();
            if (event.key != Key.none)
                return event;
        }
    }
}
