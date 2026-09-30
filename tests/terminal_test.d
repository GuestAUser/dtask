module terminal_test;

import dtask.terminal : Event, InputDecoder, Key, Terminal, fit;

private Event[] decode(string input)
{
    InputDecoder decoder;
    Event[] events;

    foreach (ubyte value; cast(const(ubyte)[]) input)
    {
        auto event = decoder.feed(value);
        if (event.key != Key.none)
            events ~= event;
    }

    return events;
}

unittest
{
    auto events = decode("a\r\n\t\x7f\x08\x03");
    Key[] expected = [Key.text, Key.enter, Key.enter, Key.tab,
        Key.backspace, Key.backspace, Key.interrupt];

    assert(events.length == expected.length);
    foreach (index, event; events)
        assert(event.key == expected[index]);

    assert(events[0].text == "a");
}


unittest
{
    auto events = decode("\x15");
    assert(events == [Event(Key.text, "\x15")]);

    /* Pasted and quarantined control bytes must never clear the form field. */
    assert(decode("\x1b[200~\x15\x1b[201~").length == 0);
    assert(decode("\x1b[\x15A").length == 0);
    assert(decode("\x1b]title\x15\x07").length == 0);
    assert(decode("\x1b\x15").length == 0);

    assert(fit("\x15", 1) == " ");
    assert(fit("a\x15b", 3) == "ab ");
}

unittest
{
    string[] sequences = ["\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D",
        "\x1b[H", "\x1b[F", "\x1b[5~", "\x1b[6~", "\x1b[3~",
        "\x1bOH", "\x1bOF", "\x1b[1;5A", "\x1b[7~", "\x1b[8~", "\x1b[Z"];
    Key[] expected = [Key.up, Key.down, Key.right, Key.left,
        Key.home, Key.end, Key.pageUp, Key.pageDown, Key.deleteKey,
        Key.home, Key.end, Key.up, Key.home, Key.end, Key.tab];

    foreach (index, sequence; sequences)
    {
        auto events = decode(sequence);
        assert(events.length == 1);
        assert(events[0].key == expected[index]);
        assert(events[0].text.length == 0);
    }
}

unittest
{
    InputDecoder decoder;
    assert(decoder.feed(0x1b).key == Key.none);
    assert(decoder.waitingForEscape);
    assert(decoder.expireEscape().key == Key.escape);
    assert(decoder.expireEscape().key == Key.none);

    decoder.feed(0x1b);
    decoder.feed('[');
    assert(!decoder.waitingForEscape);
    assert(decoder.expireEscape().key == Key.none);
    assert(decoder.feed('A').key == Key.up);

    decoder.feed(0x1b);
    decoder.feed('[');
    assert(decoder.feed(3).key == Key.interrupt);
    assert(decoder.feed('z').text == "z");
}

unittest
{
    auto events = decode("\x1b[<0;12;9M\x1b[<0;12;9m\x1b[<64;1;2M\x1b[<65;3;4M");
    assert(events.length == 4);
    assert(events[0] == Event(Key.mouse, "", 12, 9, 0, false));
    assert(events[1] == Event(Key.mouse, "", 12, 9, 0, true));
    assert(events[2].button == 64);
    assert(events[3].button == 65);

    foreach (sequence; ["\x1b[<0;0;1M", "\x1b[<0;1;0M", "\x1b[<0;1M",
        "\x1b[<0;1;2;3M", "\x1b[<;1;2M", "\x1b[<0;1;M",
        "\x1b[<2147483648;1;2M", "\x1b[<0;9999999999999999999;2M"])
        assert(decode(sequence).length == 0);
}

unittest
{
    /*
     * A drag is three distinct events, not a click followed by editable text.
     * Legacy positional constructors still default the trailing motion flag.
     */
    auto events = decode("\x1b[<0;12;9M\x1b[<32;18;11M\x1b[<0;18;11m");
    assert(events == [
        Event(Key.mouse, "", 12, 9, 0, false),
        Event(Key.mouse, "", 18, 11, 32, false, true),
        Event(Key.mouse, "", 18, 11, 0, true)
    ]);

    assert(fit("a\x1b[<32;18;11Mb", 2) == "ab");
    auto pasted = decode("\x1b[200~a\x1b[<32;18;11Mb\x1b[201~");
    assert(pasted.length == 1 && pasted[0].text == "ab" && pasted[0].pasted);
}

unittest
{
    import std.conv : to;

    /*
     * Shift, Alt and Ctrl must survive independently of button identity and
     * motion. Wheel and extended button codes retain their raw values too.
     */
    foreach (modifiers; [0, 4, 8, 16, 28])
    {
        foreach (button; [0, 1, 2, 3, 64, 65, 66, 67, 128, 129])
        {
            foreach (motionBit; [0, 32])
            {
                int rawButton = button | modifiers | motionBit;
                foreach (terminator; ["M", "m"])
                {
                    auto events = decode("\x1b[<" ~ to!string(rawButton) ~ ";7;8" ~ terminator);
                    assert(events == [Event(Key.mouse, "", 7, 8, rawButton,
                        terminator == "m", motionBit != 0)]);
                }
            }
        }
    }
}

unittest
{
    /*
     * Invalid or overlong drag reports are consumed through the CSI final
     * byte. The next ordinary character is the only editable text emitted.
     */
    foreach (sequence; ["\x1b[<32;0;1M", "\x1b[<32;1;0M", "\x1b[<32;1M",
        "\x1b[<32;1;2;3M", "\x1b[<32;;2M", "\x1b[<32;1;M",
        "\x1b[<-32;1;2M", "\x1b[<32;-1;2M", "\x1b[<32;1;2A",
        "\x1b[<2147483648;1;2M", "\x1b[<32;2147483648;2M", "\x1b[<32;1;2147483648m"])
    {
        assert(decode(sequence ~ "q") == [Event(Key.text, "q")]);
    }

    InputDecoder decoder;
    foreach (ubyte value; cast(const(ubyte)[]) "\x1b[<32;")
        assert(decoder.feed(value).key == Key.none);

    assert(decoder.expireEscape().key == Key.none);
    foreach (_; 0 .. InputDecoder.maxSequence * 2)
        assert(decoder.feed('1').key == Key.none);

    foreach (ubyte value; cast(const(ubyte)[]) ";2M")
        assert(decoder.feed(value).key == Key.none);

    assert(decoder.feed('q') == Event(Key.text, "q"));
}

unittest
{
    /* Private mode controls, including drag cleanup, are never input text. */
    auto enter = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h";
    auto leave = "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[0m\x1b[?25h\x1b[?1049l";
    assert(decode(enter ~ leave ~ "q") == [Event(Key.text, "q")]);
}

unittest
{
    /*
     * Every byte is supplied independently: no chunk-size assumption and no
     * wall-clock delay can accidentally make a fragmented sequence pass.
     */
    auto events = decode("\u4e2d\u6587e\u0301\U0001f642");
    assert(events.length == 5);
    assert(events[0].text == "\u4e2d");
    assert(events[1].text == "\u6587");
    assert(events[2].text == "e");
    assert(events[3].text == "\u0301");
    assert(events[4].text == "\U0001f642");

    foreach (invalid; ["\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80"])
    {
        auto rejected = decode(invalid);
        assert(rejected.length == 1);
        assert(rejected[0].text == "\ufffd");
    }

    auto recovered = decode("\xe2\x1b[Aq");
    assert(recovered.length == 2);
    assert(recovered[0].key == Key.up);
    assert(recovered[1].text == "q");
}

unittest
{
    auto events = decode("a\x1b[31mb\x1b]0;title\x07c\x1bPsecret\x1b\\d\x1b(Bz");
    assert(events.length == 5);
    string plain;
    foreach (event; events)
    {
        assert(event.key == Key.text);
        plain ~= event.text;
    }
    assert(plain == "abcdz");

    assert(decode("\x1b[?25l\x1b[999~\x1b_x\x1b\\").length == 0);
    assert(decode("\x1b]unterminated\ntext").length == 0);
    assert(decode("\x1b[123").length == 0);

    foreach (sequence; ["\x1bPsecret\x07still-secret\x1b\\",
        "\x1bP\u4e1cpayload\x1b\\", "\x1b]title\u4e1cpayload\x07",
        "\u009b31m", "\u009dtitle\u009c", "\x9dtitle\x9c", "\x1b[Mabc"])
    {
        auto isolated = decode(sequence ~ "q");
        assert(isolated.length == 1);
        assert(isolated[0] == Event(Key.text, "q"));
        assert(fit(sequence ~ "q", 2) == "q ");
    }

    InputDecoder decoder;
    decoder.feed(0x1b);
    decoder.feed('[');
    foreach (_; 0 .. InputDecoder.maxSequence * 10)
        assert(decoder.feed('1').key == Key.none);

    assert(decoder.expireEscape().key == Key.none);
    assert(decoder.feed('A').key == Key.none);
    assert(decoder.feed('q').text == "q");
}

unittest
{
    auto events = decode("\x1b[200~one\ntwo\t\u4e2d\x03\x1b[31m!\x1b[201~q");
    assert(events.length == 2);
    assert(events[0].key == Key.text);
    assert(events[0].text == "one\ntwo\t\u4e2d!" && events[0].pasted);
    assert(events[1] == Event(Key.text, "q"));
    assert(decode("\x1b[200~\x1b[201~").length == 0);
    auto paragraphs = decode("\x1b[200~first\r\n\r\nlast\titem\x1b[201~");
    assert(paragraphs.length == 1 && paragraphs[0].pasted);
    assert(paragraphs[0].text == "first\r\n\r\nlast\titem");
    assert(fit("\x1b[200~a\nb\tc\x1b[201~", 5) == "a b c");

    InputDecoder decoder;
    foreach (ubyte value; cast(const(ubyte)[]) "\x1b[200~")
        decoder.feed(value);

    foreach (_; 0 .. InputDecoder.maxPaste + 1000)
        assert(decoder.feed('x').key == Key.none);

    Event result;
    foreach (ubyte value; cast(const(ubyte)[]) "\x1b[201~")
        result = decoder.feed(value);

    assert(result.key == Key.text);
    assert(result.pasted);
    assert(result.text.length == InputDecoder.maxPaste);
    foreach (character; result.text)
        assert(character == 'x');
    assert(decoder.feed('q').text == "q");

    foreach (ubyte value; cast(const(ubyte)[]) "\x1b[200~")
        decoder.feed(value);
    foreach (_; 0 .. InputDecoder.maxPaste - 1)
        decoder.feed('a');
    foreach (ubyte value; cast(const(ubyte)[]) "\u4e2dz\x1b[201~")
        result = decoder.feed(value);

    /*
     * Truncation preserves a valid UTF-8 prefix, rather than admitting later
     * smaller glyphs after the first one that exceeded the byte budget.
     */
    assert(result.text.length == InputDecoder.maxPaste - 1);
    assert(result.text[$ - 1] == 'a');
}

unittest
{
    import core.stdc.locale : setlocale, LC_CTYPE;
    import std.string : fromStringz;

    auto originalLocale = fromStringz(setlocale(LC_CTYPE, null)).idup;
    scope (exit) assert(fromStringz(setlocale(LC_CTYPE, null)) == originalLocale);

    assert(fit("abc", 5) == "abc  ");
    assert(fit("abcdef", 3) == "abc");
    assert(fit("anything", 0) == "");
    assert(fit("anything", -1) == "");
    assert(fit("", 3) == "   ");
    assert(fit("\u4e2d\u6587", 5) == "\u4e2d\u6587 ");
    assert(fit("\u4e2d\u6587z", 3) == "\u4e2d ");
    assert(fit("\u4e2da", 1) == " ");
    assert(fit("e\u0301x", 1) == "e\u0301");
    assert(fit("\u0301a", 2) == "a ");
    assert(fit("a\x1b[31mb\x1b[0m", 3) == "ab ");
    assert(fit("a\x1b]52;c;attack\x07b", 3) == "ab ");
    assert(fit("a\n\tb\x00\x7f\u0085", 5) == "a  b ");
}

unittest
{
    import std.utf : validate;

    /*
     * A deterministic hostile-byte corpus checks both boundaries. The LCG
     * seed is fixed; assertions cannot depend on scheduling or locale setup.
     */
    InputDecoder decoder;
    uint random = 0x12345678;
    foreach (_; 0 .. 20_000)
    {
        random = random * 1_664_525 + 1_013_904_223;
        auto event = decoder.feed(cast(ubyte) (random >> 24));
        if (event.key != Key.text)
            continue;

        validate(event.text);
        foreach (dchar value; event.text)
            assert(value == 0x15 || (event.pasted && (value == '\r' || value == '\n' || value == '\t'))
                || (value >= 0x20 && !(value >= 0x7f && value <= 0x9f)));
    }
}

/*
 * Build with -d-version=TerminalProbe (without tests/runner.d) to exercise the
 * actual TTY boundary from a PTY driver. READY is the synchronization event;
 * tests wait for it before resizing, sending input, or delivering a signal.
 */
version (TerminalProbe)
{
    int main()
    {
        auto terminal = new Terminal;
        terminal.write("READY");

        for (;;)
        {
            auto event = terminal.readEvent();
            if (event.key == Key.interrupt)
                return 0;
            if (event.key == Key.resize)
                terminal.write("RESIZED");
            if (event.key == Key.up)
                terminal.write("UP");
            if (event.key == Key.mouse)
                terminal.write("MOUSE");
            if (event.key == Key.text && event.text == "\x15")
                terminal.write("CLEAR");
            if (event.key == Key.text && event.text == "q")
            {
                terminal.close();
                terminal.close();
                return 0;
            }
            if (event.key == Key.text && event.text == "x")
                return 0;
        }
    }
}
