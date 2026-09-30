module dtask.theme;

import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : buildPath, isAbsolute;
import std.process : environment;
import std.traits : FieldNameTuple;
import std.utf : validate;

/// Rendering palette with #RRGGBB color strings and a free-form UTF-8 name.
/// loadTheme validates colors and fills omitted fields from defaultTheme.
struct Theme
{
    /// Display name; render through fit like other externally supplied text.
    string name;
    /// Main workspace background.
    string background;
    /// Background of secondary surfaces such as schedule targets and calendar cells.
    string panel;
    /// Primary task and editor text color.
    string foreground;
    /// Secondary labels, hints and completed-task text color.
    string muted;
    /// Interactive controls and active-view highlights.
    string accent;
    /// Background for selected rows, focused fields and highlighted drop targets.
    string selected;
    /// Separator and divider color.
    string border;
    /// Urgent priority, overdue dates and error messages.
    string urgent;
    /// High-priority task label color.
    string high;
    /// Normal-priority task label color.
    string normal;
    /// Low-priority task label color.
    string low;
    /// Positive feedback, selected options and today's calendar date.
    string success;
}

/// Return the complete built-in Midnight palette; Theme.init is not a usable palette.
Theme defaultTheme()
{
    Theme theme;

    theme.name = "Midnight";
    theme.background = "#0D1117";
    theme.panel = "#161B22";
    theme.foreground = "#E6EDF3";
    theme.muted = "#8B949E";
    theme.accent = "#79C0FF";
    theme.selected = "#22334A";
    theme.border = "#30363D";
    theme.urgent = "#FF7B72";
    theme.high = "#FFA657";
    theme.normal = "#79C0FF";
    theme.low = "#8B949E";
    theme.success = "#7EE787";

    return theme;
}

/// Load a flat JSON object whose keys are Theme fields and whose values are strings.
/// Empty path returns defaultTheme; omitted keys inherit its values. Unknown keys,
/// invalid colors, malformed UTF-8/JSON and read errors throw an Exception naming the file.
Theme loadTheme(string path)
{
    auto theme = defaultTheme();

    if (path.length == 0)
    {
        return theme;
    }

    string text;

    try
    {
        text = readText(path);
    }
    catch (Exception error)
    {
        throw new Exception(format("Cannot read theme '%s': %s", path, error.msg), error);
    }

    JSONValue document;

    try
    {
        validate(text);
        document = parseJSON(text, JSONOptions.strictParsing);
    }
    catch (Exception error)
    {
        throw new Exception(format("Invalid JSON in theme '%s': %s", path, error.msg), error);
    }

    enforce(document.type == JSONType.object,
        format("Theme '%s' must contain a flat JSON object", path));

    foreach (key, value; document.object)
    {
        bool recognized;

        static foreach (field; FieldNameTuple!Theme)
        {
            if (key == field)
            {
                recognized = true;

                enforce(value.type == JSONType.string,
                    format("Theme '%s': field '%s' must be a string", path, key));

                static if (field != "name")
                {
                    enforce(validColor(value.str),
                        format("Theme '%s': color '%s' must be #RRGGBB (six hexadecimal digits)",
                            path, key));
                }

                __traits(getMember, theme, field) = value.str;
            }
        }

        enforce(recognized,
            format("Theme '%s': unknown field '%s'; use a Theme field name", path, key));
    }

    return theme;
}

// ANSI truecolor uses three byte values. For a hex pair ab, the byte is
// 16 * value(a) + value(b); validation runs before any indexing or decoding.
private bool validColor(string hex)
{
    if (hex.length != 7 || hex[0] != '#')
    {
        return false;
    }

    foreach (digit; hex[1 .. $])
    {
        if (!((digit >= '0' && digit <= '9') ||
            (digit >= 'A' && digit <= 'F') ||
            (digit >= 'a' && digit <= 'f')))
        {
            return false;
        }
    }

    return true;
}

private uint hexDigit(char digit)
{
    if (digit >= '0' && digit <= '9')
    {
        return digit - '0';
    }

    if (digit >= 'A' && digit <= 'F')
    {
        return digit - 'A' + 10;
    }

    return digit - 'a' + 10;
}

private string colorSequence(string hex, uint channel)
{
    enforce(validColor(hex), "ANSI color must be #RRGGBB (six hexadecimal digits)");

    const red = 16 * hexDigit(hex[1]) + hexDigit(hex[2]);
    const green = 16 * hexDigit(hex[3]) + hexDigit(hex[4]);
    const blue = 16 * hexDigit(hex[5]) + hexDigit(hex[6]);

    return format("\x1b[%s;2;%s;%s;%sm", channel, red, green, blue);
}

/// Encode an ANSI truecolor foreground SGR sequence; throw unless hex is #RRGGBB.
string foreground(string hex)
{
    return colorSequence(hex, 38);
}

/// Encode an ANSI truecolor background SGR sequence; throw unless hex is #RRGGBB.
string background(string hex)
{
    return colorSequence(hex, 48);
}

/// ANSI SGR sequence restoring default colors and text attributes.
enum reset = "\x1b[0m";

/// Resolve theme.json under absolute XDG_CONFIG_HOME, or HOME/.config.
/// Relative XDG values are ignored; a required missing/relative HOME throws.
/// Does not create directories or probe whether the optional file exists.
string defaultThemePath()
{
    const configHome = environment.get("XDG_CONFIG_HOME", "");

    if (configHome.length != 0 && isAbsolute(configHome))
    {
        return buildPath(configHome, "dtask", "theme.json");
    }

    const home = environment.get("HOME", "");

    enforce(home.length != 0 && isAbsolute(home),
        "Cannot resolve theme path: set an absolute XDG_CONFIG_HOME or HOME");

    return buildPath(home, ".config", "dtask", "theme.json");
}
