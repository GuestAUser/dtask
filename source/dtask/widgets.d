module dtask.widgets;

import std.datetime : Date;
import std.format : format;

/**
 * Shared cell geometry keeps drawing and hit testing on the same boundaries.
 * Coordinates are one-based terminal cells; the right/bottom edges are open.
 */
struct CellRect
{
    /// Leftmost included column.
    int x;
    /// Topmost included row.
    int y;
    /// Horizontal extent in cells; a nonpositive extent contains no cells.
    int width;
    /// Vertical extent in cells; a nonpositive extent contains no cells.
    int height;

    /// Test a one-based cell against the inclusive left/top and exclusive right/bottom edges.
    bool contains(int column, int row) const
    {
        return column >= x && column < x + width && row >= y && row < y + height;
    }
}

/// Schedule target order shared by rendering and hit testing; the last entry opens the calendar.
static immutable scheduleLabels = ["Today", "Tomorrow", "Weekend", "Next week", "No date", "Calendar"];

/// Whether the terminal has room for the side schedule panel (at least 110x24).
bool wideSchedule(int columns, int rows)
{
    return columns >= 110 && rows >= 24;
}

/// Return the rectangle for a scheduleLabels index in a terminal at least 48x20.
/// calendar forces the compact grid below the picker; otherwise use the side
/// panel when wideSchedule is true, or the compact grid above the footer.
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

/// Return the scheduleLabels index at a one-based cell, or -1 outside all targets.
/// Uses the same dimensions and layout flag as scheduleCell.
int scheduleHit(int columns, int rows, int x, int y, bool calendar = false)
{
    foreach (index; 0 .. 6)
    {
        if (scheduleCell(columns, rows, index, calendar).contains(x, y))
            return index;
    }

    return -1;
}

/// Map a zero-based column (Monday = 0) and row in a six-row grid to a day number.
/// The day in month is ignored. Return 0 for padding cells or out-of-grid coordinates.
int calendarDay(Date month, int column, int row)
{
    if (column < 0 || column >= 7 || row < 0 || row >= 6)
        return 0;

    auto first = Date(month.year, month.month, 1);
    auto leading = (cast(int) first.dayOfWeek + 6) % 7;
    auto day = row * 7 + column - leading + 1;
    return day >= 1 && day <= first.daysInMonth ? day : 0;
}

/// Return the first day of the month offset by direction (normally -1 or +1).
/// For an offset outside years 0001-9999, return the first of the original month.
/// Callers supply a month within that year range and a nonoverflowing offset.
Date adjacentMonth(Date month, int direction)
{
    auto index = (cast(int) month.year - 1) * 12 + month.month - 1 + direction;

    if (index < 0 || index >= 9999 * 12)
        return Date(month.year, month.month, 1);

    return Date(index / 12 + 1, index % 12 + 1, 1);
}

/// Format a picker selection as YYYY-MM-DD. The caller supplies a valid day for
/// the given month in years 0001-9999; this rendering helper does not validate it.
string calendarISO(Date month, int day)
{
    return format("%04d-%02d-%02d", month.year, month.month, day);
}
