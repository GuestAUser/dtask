module text_test;

import dtask.text : textWidth, wrapText;
import std.exception : assertThrown;
import std.utf : validate;

unittest
{
    assert(textWidth("") == 0);
    assert(textWidth("plain") == 5);
    assert(textWidth("\u4e2d\u6587") == 4);
    assert(textWidth("e\u0301x") == 2);
    assert(textWidth("\u0301") == 0);
    assert(textWidth("\t") == 4);
    assert(textWidth("a\tb\t") == 8);
    assert(textWidth("\u4e2d\tx") == 5);

    assert(wrapText("", 5) == [""]);
    assert(wrapText("", 0).length == 0);
    assert(wrapText("anything", -1).length == 0);
    assert(wrapText("\u4e2d", 0).length == 0);
    assert(wrapText("a", 1) == ["a"]);
    assert(wrapText("abc", 1) == ["a", "b", "c"]);
    assert(wrapText("ab cd", 1) == ["a", "b", "c", "d"]);
    assertThrown!Exception(wrapText("\u4e2d", 1));
}

unittest
{
    assert(wrapText("one two three", 7) == ["one two", "three"]);
    assert(wrapText("one two three", 6) == ["one", "two", "three"]);
    assert(wrapText("one  two", 6) == ["one", "two"]);
    assert(wrapText("abcdefghijk", 4) == ["abcd", "efgh", "ijk"]);
    assert(wrapText("hi abcdefghi end", 5) == ["hi", "abcde", "fghi", "end"]);
    assert(wrapText("12345678", 4) == ["1234", "5678"]);
    assert(wrapText(" a ", 4) == [" a "]);
    assert(wrapText("   ", 2) == ["  ", " "]);
}

unittest
{
    assert(wrapText("one\n\ntwo", 10) == ["one", "", "two"]);
    assert(wrapText("\n", 10) == ["", ""]);
    assert(wrapText("\n\n", 10) == ["", "", ""]);
    assert(wrapText("last\n\n", 4) == ["last", "", ""]);
    assert(wrapText("first long\n\nlast\n", 5) == ["first", "long", "", "last", ""]);
    assert(wrapText("one\r\ntwo", 10) == ["one", "two"]);
    assert(wrapText("\t\n", 10) == ["    ", ""]);
}

unittest
{
    assert(wrapText("a\tb", 10) == ["a   b"]);
    assert(wrapText("\ta", 10) == ["    a"]);
    assert(wrapText("abcd\tx", 10) == ["abcd    x"]);
    assert(wrapText("\u4e2d\tx", 10) == ["\u4e2d  x"]);
    assert(wrapText("e\u0301\tx", 10) == ["e\u0301   x"]);
    assert(wrapText("a\tb", 4) == ["a", "b"]);
    assert(wrapText("a\tb", 1) == ["a", "b"]);
    assert(wrapText("abcdef\tx", 4) == ["abcd", "ef", "x"]);
    assert(wrapText("a\n\tb", 10) == ["a", "    b"]);
}

unittest
{
    assert(wrapText("\u4e2d\u6587x", 2) == ["\u4e2d", "\u6587", "x"]);
    assert(wrapText("\u4e2d\u6587x", 3) == ["\u4e2d", "\u6587x"]);
    assert(wrapText("e\u0301x\u0308y", 1) == ["e\u0301", "x\u0308", "y"]);
    assert(wrapText("\u4e2d\u0301\u0308\u6587", 2) == ["\u4e2d\u0301\u0308", "\u6587"]);
    assert(wrapText("a \u0301b", 2) == ["a \u0301", "b"]);
    assert(wrapText("\u0301", 1) == ["\u0301"]);

    foreach (text; ["abcdefghijklmnopqrstuvwxyz", "\u4e2d\u0301\u6587x\u0308y", "e\u0301e\u0308z"])
    {
        foreach (columns; 2 .. 9)
        {
            string rejoined;

            foreach (line; wrapText(text, columns))
            {
                validate(line);
                assert(textWidth(line) <= columns);
                rejoined ~= line;
            }

            assert(rejoined == text);
        }
    }
}

unittest
{
    foreach (sequence; ["\x1b[31m", "\x1b[0m", "\x1b[?25l", "\x1b(B",
        "\x1b]52;c;hidden\x07", "\x1bPsecret\x07still-secret\x1b\\",
        "\x1b]title\u4e1cpayload\x07", "\u009b31m", "\u009dsecret\u009c",
        "\x9b31m", "\x9dsecret\x9c", "\x1b[Mabc", "\x1b[M\xc2\xa0x", "\x1b_\n\tsecret\x1b\\"])
    {
        assert(wrapText("a" ~ sequence ~ "b", 2) == ["ab"]);
        assert(textWidth("a" ~ sequence ~ "b") == 2);
    }

    assert(wrapText("a\x00\x03\x15\x7f\u0085b", 2) == ["ab"]);
    assert(wrapText("a\x1b]unterminated\nsecret", 2) == ["a"]);
    assert(wrapText("a\x1b[123", 2) == ["a"]);
    assert(wrapText("a\x1bPsecret\x03still-secret\x1b\\b", 2) == ["ab"]);
    assert(wrapText("\x1b[200~one\ntwo\t!\x1b[201~", 8) == ["one", "two !"]);
    assert(wrapText("a\xff" ~ "b", 3) == ["a\ufffdb"]);
    assert(wrapText("a\xc2" ~ "b", 3) == ["a\ufffdb"]);

    /* Stored descriptions must not inherit the keyboard decoder's paste cap. */
    import std.array : replicate;

    auto large = "x".replicate(70_000);

    string rejoined;
    foreach (line; wrapText("\x1b[200~" ~ large ~ "\x1b[201~", 79))
    {
        assert(textWidth(line) <= 79);
        rejoined ~= line;
    }

    assert(rejoined == large);
}

unittest
{
    import core.stdc.locale : setlocale, LC_CTYPE;
    import core.sys.posix.locale : newlocale, freelocale, uselocale, LC_CTYPE_MASK;
    import std.string : fromStringz;

    immutable processLocale = fromStringz(setlocale(LC_CTYPE, null)).idup;
    auto locale = newlocale(LC_CTYPE_MASK, "C", null);
    assert(locale !is null);
    scope (exit) freelocale(locale);

    auto previous = uselocale(locale);
    assert(previous !is null);
    scope (exit) uselocale(previous);

    assert(textWidth("\u4e2de\u0301") == 3);
    assert(uselocale(null) == locale);
    assert(wrapText("\u4e2de\u0301", 2) == ["\u4e2d", "e\u0301"]);
    assert(uselocale(null) == locale);
    assertThrown!Exception(wrapText("\u4e2d", 1));
    assert(uselocale(null) == locale);
    assert(wrapText("anything", 0).length == 0);
    assert(uselocale(null) == locale);
    assert(fromStringz(setlocale(LC_CTYPE, null)) == processLocale);
}
