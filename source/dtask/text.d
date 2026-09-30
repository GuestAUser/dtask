module dtask.text;

import core.sys.posix.locale : locale_t, newlocale, freelocale, uselocale, LC_CTYPE_MASK;
import std.exception : enforce;
import std.utf : decode, encode, UTFException;

/* POSIX wchar_t is a 32-bit scalar on the supported platforms. */
private extern (C) int wcwidth(dchar value) nothrow @nogc;

private locale_t characterLocale()
{
    auto locale = newlocale(LC_CTYPE_MASK, "C.UTF-8", null);
    if (locale is null)
        locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", null);
    if (locale is null)
        locale = newlocale(LC_CTYPE_MASK, "", null);

    enforce(locale !is null, "Cannot create a character-width locale");
    return locale;
}

/*
 * Stored text is not keyboard input: paste markers must not cap its length,
 * Ctrl-C must not reset sequence quarantine, and LF/tab must survive unchanged.
 */
private dchar[] printableText(string text)
{
    enum State { ground, escape, intermediate, sequence, controlString, stringEscape, legacyMouse }
    State state;
    bool osc;
    bool sequenceEmpty;
    int mouseBytes;
    dchar[] result;
    size_t offset;

    while (offset < text.length)
    {
        if (state == State.legacyMouse)
        {
            ++offset;
            if (--mouseBytes == 0)
                state = State.ground;

            continue;
        }

        /* Accept raw 8-bit C1 controls as well as their UTF-8 encoded forms. */
        const rawByte = cast(ubyte) text[offset];
        dchar value;

        if (rawByte >= 0x80 && rawByte <= 0x9f)
            value = cast(dchar) text[offset++];
        else
        {
            const start = offset;

            try
                value = decode(text, offset);
            catch (UTFException)
            {
                /* Replace only the bad byte, not any following printable text. */
                offset = start + 1;
                value = '\ufffd';
            }
        }

        if (state == State.controlString || state == State.stringEscape)
        {
            if (value == 0x9c || (osc && value == 7) ||
                (state == State.stringEscape && value == '\\'))
                state = State.ground;
            else
                state = value == 0x1b ? State.stringEscape : State.controlString;

            continue;
        }

        if (value == 0x1b)
        {
            state = State.escape;
            continue;
        }

        if (state == State.escape)
        {
            if (value == '[' || value == 'O')
            {
                state = State.sequence;
                sequenceEmpty = true;
            }
            else if (value == ']' || value == 'P' || value == 'X' || value == '^' || value == '_')
            {
                state = State.controlString;
                osc = value == ']';
            }
            else
                state = value >= 0x20 && value <= 0x2f ? State.intermediate : State.ground;

            continue;
        }

        if (state == State.intermediate)
        {
            if (value >= 0x30 && value <= 0x7e)
                state = State.ground;

            continue;
        }

        if (state == State.sequence)
        {
            if (value >= 0x40 && value <= 0x7e)
            {
                state = value == 'M' && sequenceEmpty ? State.legacyMouse : State.ground;
                mouseBytes = 3;
            }
            else
                sequenceEmpty = false;

            continue;
        }

        if (value == 0x9b || value == 0x8f)
        {
            state = State.sequence;
            sequenceEmpty = true;
        }
        else if (value == 0x9d || value == 0x90 || value == 0x98 || value == 0x9e || value == 0x9f)
        {
            state = State.controlString;
            osc = value == 0x9d;
        }
        else if (value == '\n' || value == '\t' ||
            (value >= 0x20 && !(value >= 0x7f && value <= 0x9f)))
            result ~= value;
    }

    return result;
}

/**
 * Return the POSIX display-cell width of a printable line, not its UTF-8 length.
 *
 * Terminal sequences and nonprinting controls are removed. Tabs advance to
 * four-column stops; LF counts as a space when measuring single-line text.
 * Combining marks occupy zero cells, and CJK widths match terminal.fit.
 * Uses a private thread locale, restoring it without changing the process locale.
 * Throws: Exception if a character-width locale cannot be created or selected.
 */
int textWidth(string text)
{
    auto locale = characterLocale();
    scope (exit) freelocale(locale);

    auto previous = uselocale(locale);
    enforce(previous !is null, "Cannot select a character-width locale");
    scope (exit) uselocale(previous);

    int cells;

    foreach (value; printableText(text))
    {
        if (value == '\t')
            cells += 4 - cells % 4;
        else if (value == '\n')
            ++cells;
        else
        {
            const count = wcwidth(value);
            if (count > 0)
                cells += count;
        }
    }

    return cells;
}

private struct Glyph
{
    string text;
    int cells;
    bool space;
}

private string glyphText(Glyph[] glyphs)
{
    char[] result;

    foreach (glyph; glyphs)
        result ~= glyph.text;

    return cast(string) result;
}

private string[] wrapParagraph(Glyph[] glyphs, int columns)
{
    if (!glyphs.length)
        return [""];

    string[] lines;
    size_t start;

    while (start < glyphs.length)
    {
        size_t end = start;
        size_t breakAt = start;
        int cells;

        while (end < glyphs.length && glyphs[end].cells <= columns - cells)
        {
            if (glyphs[end].space && end > start && !glyphs[end - 1].space)
                breakAt = end;

            cells += glyphs[end].cells;
            ++end;
        }

        if (end == glyphs.length)
        {
            lines ~= glyphText(glyphs[start .. end]);
            break;
        }

        /* A separator just beyond an exact fit is also a word boundary. */
        if (glyphs[end].space && end > start && !glyphs[end - 1].space)
            breakAt = end;

        if (breakAt > start)
        {
            lines ~= glyphText(glyphs[start .. breakAt]);
            start = breakAt;

            while (start < glyphs.length && glyphs[start].space)
                ++start;
        }
        else
        {
            lines ~= glyphText(glyphs[start .. end]);
            start = end;
        }
    }

    return lines;
}

/**
 * Word-wrap stored text into lines of at most columns terminal display cells.
 *
 * LF preserves paragraph boundaries, including blank and trailing lines. Tabs
 * expand at four-column stops in each input paragraph before wrapping. Spaces
 * used as soft-wrap separators are omitted; other spaces remain unchanged.
 * Long words break between scalars, keeping zero-width marks with their base.
 * Terminal sequences and nonprinting controls are removed, never rendered.
 * Malformed UTF-8 becomes replacement characters. Input data is never changed.
 * Empty input returns one empty line; nonpositive columns returns no lines.
 * Uses and restores a private thread locale, leaving the process locale intact.
 * Throws: Exception on locale failure, or if columns cannot hold an indivisible
 * glyph (for example, a two-cell CJK glyph at width one). This avoids both
 * silent content loss and lines wider than the requested width.
 */
string[] wrapText(string text, int columns)
{
    if (columns <= 0)
        return [];

    auto locale = characterLocale();
    scope (exit) freelocale(locale);

    auto previous = uselocale(locale);
    enforce(previous !is null, "Cannot select a character-width locale");
    scope (exit) uselocale(previous);

    string[] lines;
    Glyph[] paragraph;
    int tabColumn;

    foreach (value; printableText(text))
    {
        if (value == '\n')
        {
            lines ~= wrapParagraph(paragraph, columns);
            paragraph = null;
            tabColumn = 0;
            continue;
        }

        if (value == '\t')
        {
            foreach (_; 0 .. 4 - tabColumn)
                paragraph ~= Glyph(" ", 1, true);

            tabColumn = 0;
            continue;
        }

        const count = wcwidth(value);
        if (count < 0)
            continue;

        enforce(count <= columns, "Wrap width cannot hold a character");

        char[4] bytes;
        const length = encode(bytes, value);
        auto encoded = bytes[0 .. length].idup;

        if (count == 0 && paragraph.length)
        {
            paragraph[$ - 1].text ~= encoded;
            /* A space carrying marks is content, not a disposable separator. */
            paragraph[$ - 1].space = false;
        }
        else
            paragraph ~= Glyph(encoded, count, value == ' ');

        tabColumn = (tabColumn + count) % 4;
    }

    lines ~= wrapParagraph(paragraph, columns);
    return lines;
}
