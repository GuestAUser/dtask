module text_test;

import dtask.text : fitText, graphemeBoundaries, graphemePrefixBytes, textWidth, wrapText;
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

unittest
{
    import std.conv : to;
    import std.uni : byGrapheme;

    string[] samples = ["", "e\u0301", "\U0001f44d\U0001f3fd",
        "\U0001f469\u200d\U0001f4bb", "\U0001f468\u200d\U0001f469\u200d\U0001f467",
        "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466",
        "\U0001f1fa\U0001f1f8", "1\ufe0f\u20e3", "1\u20e3", "\u2764\ufe0f",
        "\u2764\ufe0e", "\u4e2d\u6587", "\u0301\u0308a", "\u0301",
        "\U0001f1fa\U0001f1f8\U0001f1e8", "\U0001f1fa\U0001f1f8\U0001f1e8\U0001f1e6",
        "\r\n", "\u1100\u1161\u11a8", "\u0915\u094d\u0937"];
    size_t[][] expected = [[0], [0, 2], [0, 2], [0, 3], [0, 5], [0, 7],
        [0, 2], [0, 3], [0, 2], [0, 2], [0, 2], [0, 1, 2], [0, 2, 3], [0, 1],
        [0, 2, 3], [0, 2, 4], [0, 2], [0, 3], [0, 2, 3]];

    foreach (index, sample; samples)
    {
        auto points = to!dstring(sample);
        auto boundaries = graphemeBoundaries(points);
        assert(boundaries == expected[index]);

        size_t[] iterated = [0];
        foreach (cluster; points.byGrapheme)
            iterated ~= iterated[$ - 1] + cluster.length;

        assert(iterated == boundaries);

        foreach (budget; 0 .. sample.length + 2)
        {
            size_t prefix;
            foreach (boundary; boundaries)
            {
                auto bytes = to!string(points[0 .. boundary]).length;
                if (bytes <= budget)
                    prefix = bytes;
            }

            assert(graphemePrefixBytes(sample, budget) == prefix);
        }
    }
}

unittest
{
    import std.array : replicate;

    string[] clusters = ["e\u0301", "\U0001f44d\U0001f3fd", "\U0001f469\u200d\U0001f4bb",
        "\U0001f468\u200d\U0001f469\u200d\U0001f467",
        "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466",
        "\U0001f1e7\U0001f1f7", "\u4e2d", "1\ufe0f\u20e3", "1\u20e3",
        "\u2764\ufe0f", "\u2764\ufe0e"];
    int[] widths = [1, 2, 2, 2, 2, 2, 2, 2, 1, 2, 1];

    foreach (index, cluster; clusters)
    {
        const width = widths[index];
        assert(textWidth(cluster) == width);
        assert(fitText(cluster, width - 1) == " ".replicate(width - 1));
        assert(fitText(cluster, width) == cluster);
        assert(fitText(cluster, width + 1) == cluster ~ " ");
        assert(fitText("A" ~ cluster ~ "B", width) == "A" ~ " ".replicate(width - 1));
        assert(wrapText(cluster ~ cluster, width) == [cluster, cluster]);
        assert(wrapText(cluster ~ "\tx", 8) == [cluster ~ " ".replicate(4 - width) ~ "x"]);

        if (width > 1)
            assertThrown!Exception(wrapText(cluster, width - 1));
    }

    assert(textWidth("\U0001f1fa\U0001f1f8\U0001f1e8") == 3);
    assert(textWidth("\u0301\u0308\ufe0f") == 0);
    assert(fitText("\u0301\u0308a", 2) == "a ");
    assert(fitText("\u0301\ufe0f", 2) == "  ");
    assert(wrapText("\u0301\u0308", 1) == ["\u0301\u0308"]);
    assert(wrapText("a\t\u0301b", 5) == ["a   \u0301b"]);
}

unittest
{
    import core.stdc.locale : setlocale, LC_CTYPE;
    import core.sys.posix.locale : newlocale, freelocale, uselocale, LC_CTYPE_MASK;
    import std.array : replicate;
    import std.string : fromStringz;

    immutable processLocale = fromStringz(setlocale(LC_CTYPE, null)).idup;
    auto locale = newlocale(LC_CTYPE_MASK, "C", null);
    assert(locale !is null);
    scope (exit) freelocale(locale);

    auto previous = uselocale(locale);
    assert(previous !is null);
    scope (exit) uselocale(previous);

    auto large = "x".replicate(70_000);
    assert(fitText("\x1b[200~" ~ large ~ "\x1b[201~", 70_001) == large ~ " ");

    foreach (sequence; ["\x1b]hidden\x03still-hidden\x07", "\x1bPsecret\x03tail\x1b\\",
        "\x9dsecret\x9c", "\u009dsecret\u009c", "\x1b_\r\n\tsecret\x1b\\"])
        assert(fitText("a" ~ sequence ~ "b", 3) == "ab ");

    assert(fitText("a\xff" ~ "b", 3) == "a\ufffdb");
    assert(fitText("a\xc2" ~ "b", 3) == "a\ufffdb");
    assert(fitText("a\r\n\tb", 5) == "a   b");
    assert(fitText("\U0001f469\u200d\U0001f4bb", 2) == "\U0001f469\u200d\U0001f4bb");
    assert(uselocale(null) == locale);
    assert(fitText("anything", 0) == "");
    assert(uselocale(null) == locale);
    assertThrown!Exception(wrapText("\U0001f469\u200d\U0001f4bb", 1));
    assert(uselocale(null) == locale);
    assert(fromStringz(setlocale(LC_CTYPE, null)) == processLocale);
}
