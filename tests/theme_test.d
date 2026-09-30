module theme_test;

import dtask.theme;

import core.sys.posix.stdlib : mkdtemp;
import std.exception : assertThrown, enforce;
import std.file : readText, rmdirRecurse, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : environment;
import std.string : fromStringz, indexOf;
import std.traits : FieldNameTuple;

/*
 * Each file-based test owns a fresh directory, without timing assumptions or
 * shared filenames. Cleanup also runs when an assertion fails.
 */
private string themeDirectory()
{
    auto pattern = (buildPath(tempDir(), "dtask-theme-XXXXXX") ~ "\0").dup;

    enforce(mkdtemp(pattern.ptr) !is null, "Could not create theme test directory");

    return fromStringz(pattern.ptr).idup;
}

private void expectThemeFailure(string path, string contents, string field = "")
{
    write(path, contents);

    Exception failure;

    try
    {
        loadTheme(path);
    }
    catch (Exception error)
    {
        failure = error;
    }

    assert(failure !is null);
    assert(failure.msg.indexOf(path) >= 0);

    if (field.length != 0)
    {
        assert(failure.msg.indexOf(field) >= 0);
    }
}

/* Built-in values and inheritance for every optional field. */
unittest
{
    auto theme = defaultTheme();

    assert(theme.background == "#0D1117");
    assert(theme.panel == "#161B22");
    assert(theme.foreground == "#E6EDF3");
    assert(theme.muted == "#8B949E");
    assert(theme.accent == "#79C0FF");
    assert(theme.selected == "#22334A");
    assert(theme.border == "#30363D");
    assert(theme.urgent == "#FF7B72");
    assert(theme.high == "#FFA657");
    assert(theme.normal == "#79C0FF");
    assert(theme.low == "#8B949E");
    assert(theme.success == "#7EE787");
    assert(loadTheme("") == theme);

    auto directory = themeDirectory();
    scope (exit) rmdirRecurse(directory);

    auto path = buildPath(directory, "theme.json");
    write(path, "{}");

    assert(loadTheme(path) == theme);

    static foreach (field; FieldNameTuple!Theme)
    {
        {
            auto value = field == "name" ? "Custom theme" : "#aAbBcC";
            JSONValue document = JSONValue(string[string].init);
            document[field] = value;
            write(path, document.toString());

            auto expected = theme;
            __traits(getMember, expected, field) = value;

            assert(loadTheme(path) == expected);
        }
    }
}

/* Both shipped themes are complete JSON examples consumed by the real loader. */
unittest
{
    foreach (filename; ["midnight.json", "ember.json"])
    {
        auto path = buildPath("themes", filename);
        auto document = parseJSON(readText(path));
        auto theme = loadTheme(path);

        assert(document.object.length == FieldNameTuple!Theme.length);

        static foreach (field; FieldNameTuple!Theme)
        {
            assert(__traits(getMember, theme, field) == document[field].str);

            static if (field != "name")
            {
                assert(foreground(__traits(getMember, theme, field)).length > 0);
                assert(background(__traits(getMember, theme, field)).length > 0);
            }
        }
    }

    assert(loadTheme(buildPath("themes", "midnight.json")) == defaultTheme());
    assert(loadTheme(buildPath("themes", "ember.json")).background != defaultTheme().background);
}

/*
 * Malformed syntax, non-object roots, unknown keys and non-string fields must
 * fail at the configuration boundary, with the file and offending field known.
 */
unittest
{
    auto directory = themeDirectory();
    scope (exit) rmdirRecurse(directory);

    auto path = buildPath(directory, "theme.json");

    foreach (contents; ["", "{", "[]", "null", "true", "42", `"theme"`,
        `{"accent":"#123456",}`, `{"accent":NaN}`, `{"name":TRUE}`,
        "{/* comment */}", "{} trailing", "{\"name\":\"\xFF\"}"])
    {
        expectThemeFailure(path, contents);
    }

    foreach (field; ["colors", "Background", "unknown"])
    {
        JSONValue document = JSONValue(string[string].init);
        document[field] = "#123456";

        expectThemeFailure(path, document.toString(), field);
    }

    static foreach (field; FieldNameTuple!Theme)
    {
        foreach (value; ["null", "true", "123", "[]", "{}"])
        {
            expectThemeFailure(path, `{"` ~ field ~ `":` ~ value ~ `}`, field);
        }
    }

    auto missingPath = buildPath(directory, "missing.json");
    Exception failure;

    try
    {
        loadTheme(missingPath);
    }
    catch (Exception error)
    {
        failure = error;
    }

    assert(failure !is null);
    assert(failure.msg.indexOf(missingPath) >= 0);
}

unittest
{
    auto directory = themeDirectory();
    scope (exit) rmdirRecurse(directory);

    auto path = buildPath(directory, "theme.json");

    foreach (color; ["", "123456", "#123", "#12345", "#1234567", "#GG0000",
        "#12 456", " #123456", "#123456 ", "#12345\n", "#\uFF11\uFF12\uFF13"])
    {
        static foreach (field; FieldNameTuple!Theme)
        {
            static if (field != "name")
            {
                {
                    JSONValue document = JSONValue(string[string].init);
                    document[field] = color;

                    expectThemeFailure(path, document.toString(), field);
                }
            }
        }

        assertThrown!Exception(foreground(color));
        assertThrown!Exception(background(color));
    }
}

/* Exact SGR bytes are machine-consumed output, including decimal RGB channels. */
unittest
{
    assert(foreground("#000000") == "\x1b[38;2;0;0;0m");
    assert(background("#FFFFFF") == "\x1b[48;2;255;255;255m");
    assert(foreground("#79C0FF") == "\x1b[38;2;121;192;255m");
    assert(background("#0D1117") == "\x1b[48;2;13;17;23m");
    assert(foreground("#aAbBcC") == "\x1b[38;2;170;187;204m");
    assert(background("#01020f") == "\x1b[48;2;1;2;15m");
    assert(reset == "\x1b[0m");
}

/* Environment changes are process-local and restored even on assertion failure. */
unittest
{
    const originalConfig = environment.get("XDG_CONFIG_HOME");
    const originalHome = environment.get("HOME");

    scope (exit)
    {
        if (originalConfig is null)
        {
            environment.remove("XDG_CONFIG_HOME");
        }
        else
        {
            environment["XDG_CONFIG_HOME"] = originalConfig;
        }

        if (originalHome is null)
        {
            environment.remove("HOME");
        }
        else
        {
            environment["HOME"] = originalHome;
        }
    }

    environment["XDG_CONFIG_HOME"] = "/tmp/dtask-config";
    environment["HOME"] = "/tmp/dtask-home";

    assert(defaultThemePath() == "/tmp/dtask-config/dtask/theme.json");

    environment["XDG_CONFIG_HOME"] = "relative-config";

    assert(defaultThemePath() == "/tmp/dtask-home/.config/dtask/theme.json");

    environment["XDG_CONFIG_HOME"] = "";

    assert(defaultThemePath() == "/tmp/dtask-home/.config/dtask/theme.json");

    environment.remove("XDG_CONFIG_HOME");

    assert(defaultThemePath() == "/tmp/dtask-home/.config/dtask/theme.json");

    environment.remove("HOME");

    assertThrown!Exception(defaultThemePath());

    environment["HOME"] = "relative-home";

    assertThrown!Exception(defaultThemePath());

    environment["XDG_CONFIG_HOME"] = "relative-config";

    assertThrown!Exception(defaultThemePath());

    environment["XDG_CONFIG_HOME"] = "/tmp/dtask-config";

    assert(defaultThemePath() == "/tmp/dtask-config/dtask/theme.json");

    environment.remove("HOME");

    assert(defaultThemePath() == "/tmp/dtask-config/dtask/theme.json");
}
