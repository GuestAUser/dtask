module dtask.widgets;

import std.datetime : Date;
import std.format : format;
import std.algorithm : min, max;
import std.conv : to;
import dtask.text : textWidth, wrapText;

/** A help shortcut, section heading, or wrapped continuation line. */
struct HelpRow
{
    string key;
    string text;
    bool heading;
}

/** Reserved key column, shared by help wrapping and rendering. */
enum helpKeyWidth = 18;

/** Wrap descriptions without losing their key-column alignment. */
HelpRow[] wrapHelpRows(scope const(HelpRow)[] entries, int width)
{
    HelpRow[] result;

    foreach (entry; entries)
    {
        auto lines = wrapText(entry.text, entry.heading ? width : width - helpKeyWidth);

        foreach (index, text; lines)
            result ~= HelpRow(index == 0 ? entry.key : "", text, entry.heading);
    }

    return result;
}

/** Reserve unused workspace for a preview, without moving row eight or dates. */
int taskListHeight(int columns, int rows, int count)
{
    auto available = max(1, rows - (wideSchedule(columns, rows) ? 12 : 14));
    return available >= 12 && count > 0 ? min(max(3, count), available - 9) : available;
}

/** Full reader/editor body; its controls and toolbar are below this rectangle. */
CellRect descriptionBody(int columns, int rows)
{
    return CellRect(3, 8, columns - 4, rows - 13);
}

/** Editor rows retain code-point offsets, including soft-wrap boundaries. */
struct DraftLine
{
    /** Display text for this visual row, with tabs expanded to spaces. */
    string text;
    /** Inclusive code-point offset in the original, unmodified description. */
    size_t start;
    /** Exclusive code-point offset, excluding a terminating newline. */
    size_t end;
}

/** Hard-wrap editable text while retaining all whitespace and cursor positions. */
DraftLine[] draftLines(string text, int width)
{
    auto points = to!dstring(text);
    DraftLine[] lines;
    size_t start;
    int cells;
    string rendered;

    foreach (index, point; points)
    {
        auto glyph = to!string(point);
        auto count = point == '\t' ? 4 - cells % 4 : textWidth(glyph);

        if (point == '\n' || (cells + count > width && cells > 0))
        {
            lines ~= DraftLine(rendered, start, index);
            rendered = "";
            cells = 0;
            start = point == '\n' ? index + 1 : index;

            if (point == '\n')
                continue;

            count = point == '\t' ? 4 : textWidth(glyph);
        }

        rendered ~= point == '\t' ? "    "[0 .. count] : glyph;
        cells += count;
    }

    lines ~= DraftLine(rendered, start, points.length);
    return lines;
}

/** At a soft boundary the cursor belongs to the following visual row. */
int draftCursorRow(DraftLine[] lines, size_t cursor)
{
    int row;

    foreach (index, line; lines)
    {
        if (line.start <= cursor)
            row = cast(int) index;
    }

    return row;
}

/**
 * Map a display column to a code-point cursor in the requested visual row.
 * A soft-wrap endpoint belongs to the next row, so clamp it to this row's
 * final glyph. Explicit newline and end-of-text positions remain reachable.
 */
size_t draftCursorAt(string text, DraftLine line, int column)
{
    auto points = to!dstring(text);
    int cells;
    auto cursor = line.start;

    while (cursor < line.end)
    {
        auto count = points[cursor] == '\t' ? 4 - cells % 4 : textWidth(to!string(points[cursor]));

        if (cells + count > column)
            break;

        cells += count;
        ++cursor;
    }

    if (cursor == line.end && cursor > line.start
        && cursor < points.length && points[cursor] != '\n')
    {
        do
            --cursor;
        while (cursor > line.start && textWidth(to!string(points[cursor])) == 0);
    }

    return cursor;
}

/**
 * Shared cell geometry keeps drawing and hit testing on the same boundaries.
 * Coordinates are one-based terminal cells; the right/bottom edges are open.
 */
struct CellRect
{
    /** Leftmost included column. */
    int x;
    /** Topmost included row. */
    int y;
    /** Horizontal extent in cells; a nonpositive extent contains no cells. */
    int width;
    /** Vertical extent in cells; a nonpositive extent contains no cells. */
    int height;

    /** Test a one-based cell against the inclusive left/top and exclusive right/bottom edges. */
    bool contains(int column, int row) const
    {
        return column >= x && column < x + width && row >= y && row < y + height;
    }
}

/** Schedule target order shared by rendering and hit testing; the last entry opens the calendar. */
static immutable scheduleLabels = ["Today", "Tomorrow", "Weekend", "Next week", "No date", "Calendar"];

/** Whether the terminal has room for the side schedule panel (at least 110x24). */
bool wideSchedule(int columns, int rows)
{
    return columns >= 110 && rows >= 24;
}

/**
 * Return the rectangle for a scheduleLabels index in a terminal at least 48x20.
 * calendar forces the compact grid below the picker; otherwise use the side
 * panel when wideSchedule is true, or the compact grid above the footer.
 */
CellRect scheduleCell(int columns, int rows, int index, bool calendar = false)
{
    if (!calendar && wideSchedule(columns, rows))
    {
        auto height = rows >= 29 ? 3 : 2;
        return CellRect(columns - 31, 9 + index * height, 30, index == 5 ? 1 : height);
    }

    auto width = (columns - 4) / 3;
    auto top = calendar ? 15 : rows - 6;
    return CellRect(3 + (index % 3) * width, top + index / 3, width, 1);
}

/**
 * Return the scheduleLabels index at a one-based cell, or -1 outside all targets.
 * Uses the same dimensions and layout flag as scheduleCell.
 */
int scheduleHit(int columns, int rows, int x, int y, bool calendar = false)
{
    foreach (index; 0 .. 6)
    {
        if (scheduleCell(columns, rows, index, calendar).contains(x, y))
            return index;
    }

    return -1;
}

/**
 * Map a zero-based column (Monday = 0) and row in a six-row grid to a day number.
 * The day in month is ignored. Return 0 for padding cells or out-of-grid coordinates.
 */
int calendarDay(Date month, int column, int row)
{
    if (column < 0 || column >= 7 || row < 0 || row >= 6)
        return 0;

    auto first = Date(month.year, month.month, 1);
    auto leading = (cast(int) first.dayOfWeek + 6) % 7;
    auto day = row * 7 + column - leading + 1;
    return day >= 1 && day <= first.daysInMonth ? day : 0;
}

/**
 * Return the first day of the month offset by direction (normally -1 or +1).
 * For an offset outside years 0001-9999, return the first of the original month.
 * Callers supply a month within that year range and a nonoverflowing offset.
 */
Date adjacentMonth(Date month, int direction)
{
    auto index = (cast(int) month.year - 1) * 12 + month.month - 1 + direction;

    if (index < 0 || index >= 9999 * 12)
        return Date(month.year, month.month, 1);

    return Date(index / 12 + 1, index % 12 + 1, 1);
}

/**
 * Format a picker selection as YYYY-MM-DD. The caller supplies a valid day for
 * the given month in years 0001-9999; this rendering helper does not validate it.
 */
string calendarISO(Date month, int day)
{
    return format("%04d-%02d-%02d", month.year, month.month, day);
}
