module ui_test;

import dtask.widgets;
import std.datetime : Date;
import dtask.text : textWidth;

unittest
{
    const entries = [
        HelpRow("", "A section heading", true),
        HelpRow("Ctrl-U", "A long description that must wrap onto aligned continuation rows."),
        HelpRow("", ""),
        HelpRow("Enter", "Short text")
    ];

    foreach (width; [44, 56, 76])
    {
        auto lines = wrapHelpRows(entries, width);
        assert(lines[0].heading && lines[0].key.length == 0);
        assert(lines[1].key == entries[1].key);
        size_t keys;
        size_t blanks;

        foreach (line; lines)
        {
            assert(textWidth(line.text) <= (line.heading ? width : width - helpKeyWidth));
            assert(textWidth(line.key) < helpKeyWidth);

            if (line.key.length)
                ++keys;
            else if (!line.text.length)
                ++blanks;
        }

        assert(keys == 2);
        assert(blanks == 1);
        assert(lines[$ - 1].key == entries[$ - 1].key);
    }
}

unittest
{
    auto cell = CellRect(3, 8, 10, 2);
    assert(cell.contains(3, 8));
    assert(cell.contains(12, 9));
    assert(!cell.contains(2, 8));
    assert(!cell.contains(13, 8));
    assert(!cell.contains(3, 10));
}

unittest
{
    /*
     * Every scheduling rectangle remains visible and disjoint at each layout
     * boundary. Hit testing agrees with drawing for every cell, not just labels.
     */
    foreach (size; [[48, 20], [60, 24], [80, 24], [109, 32], [110, 24], [120, 28], [120, 29], [120, 32], [120, 20]])
    {
        foreach (calendar; [false, true])
        {
            foreach (index; 0 .. 6)
            {
                auto cell = scheduleCell(size[0], size[1], index, calendar);
                assert(cell.x >= 1 && cell.y >= 1);
                assert(cell.x + cell.width <= size[0] + 1);
                assert(cell.y + cell.height <= size[1] - (calendar ? 3 : 4));
                assert(cell.width >= 11);

                foreach (row; cell.y .. cell.y + cell.height)
                {
                    foreach (column; cell.x .. cell.x + cell.width)
                        assert(scheduleHit(size[0], size[1], column, row, calendar) == index);
                }
            }

            assert(scheduleHit(size[0], size[1], 1, 1, calendar) == -1);
            assert(scheduleHit(size[0], size[1], size[0], size[1], calendar) == -1);
        }
    }

    assert(scheduleCell(120, 32, 3) == CellRect(89, 18, 30, 3));
    assert(scheduleCell(80, 24, 3) == CellRect(3, 19, 25, 1));
    assert(scheduleCell(48, 20, 3) == CellRect(3, 15, 14, 1));
}

unittest
{
    /*
     * Every day appears exactly once in the six-row grid, including February
     * and months starting Sunday that need their sixth calendar row.
     */
    foreach (year; [1, 1900, 2000, 2024, 2026, 9999])
    {
        foreach (month; 1 .. 13)
        {
            auto first = Date(year, month, 1);
            int[] days;

            foreach (row; 0 .. 6)
            {
                foreach (column; 0 .. 7)
                {
                    auto day = calendarDay(first, column, row);

                    if (day != 0)
                    {
                        days ~= day;
                        assert((cast(int) Date(year, month, day).dayOfWeek + 6) % 7 == column);
                    }
                }
            }

            assert(days.length == first.daysInMonth);

            foreach (index, day; days)
                assert(day == index + 1);
        }
    }

    assert(calendarDay(Date(2026, 3, 1), 0, 5) == 30);
    assert(calendarDay(Date(2026, 3, 1), 1, 5) == 31);
    assert(calendarDay(Date(2026, 3, 1), 2, 5) == 0);
    assert(calendarDay(Date(2026, 3, 1), -1, 0) == 0);
    assert(calendarDay(Date(2026, 3, 1), 7, 0) == 0);
    assert(calendarDay(Date(2026, 3, 1), 0, 6) == 0);
    assert(calendarISO(Date(2024, 2, 1), 29) == "2024-02-29");
    assert(calendarISO(Date(1, 1, 1), 1) == "0001-01-01");
}

unittest
{
    assert(adjacentMonth(Date(2024, 12, 1), 1) == Date(2025, 1, 1));
    assert(adjacentMonth(Date(2025, 1, 1), -1) == Date(2024, 12, 1));
    assert(adjacentMonth(Date(2024, 3, 31), -1) == Date(2024, 2, 1));
    assert(adjacentMonth(Date(1, 1, 1), -1) == Date(1, 1, 1));
    assert(adjacentMonth(Date(9999, 12, 1), 1) == Date(9999, 12, 1));
}

unittest
{
    foreach (size; [[48, 20], [60, 24], [80, 28], [109, 32], [110, 24], [120, 32]])
    {
        auto body = descriptionBody(size[0], size[1]);
        assert(body.x == 3 && body.y == 8);
        assert(body.width == size[0] - 4 && body.height >= 7);
        assert(body.y + body.height == size[1] - 5);

        foreach (count; [0, 1, 3, 12, 100])
        {
            auto height = taskListHeight(size[0], size[1], count);
            assert(height >= 1);

            foreach (index; 0 .. 6)
            {
                auto target = scheduleCell(size[0], size[1], index);
                assert(wideSchedule(size[0], size[1]) || 8 + height <= target.y);
            }
        }
    }

    assert(taskListHeight(120, 32, 2) == 3);
    assert(taskListHeight(120, 32, 100) == 11);
    assert(taskListHeight(48, 20, 2) == 6);
    assert(taskListHeight(120, 32, 0) == 20);
}

unittest
{
    auto lines = draftLines("abcd\n\nefghij\n", 4);
    assert(lines == [DraftLine("abcd", 0, 4), DraftLine("", 5, 5),
        DraftLine("efgh", 6, 10), DraftLine("ij", 10, 12), DraftLine("", 13, 13)]);
    assert(draftCursorRow(lines, 4) == 0);
    assert(draftCursorRow(lines, 5) == 1);
    assert(draftCursorRow(lines, 10) == 3);
    assert(draftCursorRow(lines, 13) == 4);
    assert(draftLines("", 4) == [DraftLine("", 0, 0)]);
}

unittest
{
    auto text = "a\t星e\u0301図";
    auto lines = draftLines(text, 7);
    assert(lines == [DraftLine("a   星e\u0301", 0, 5), DraftLine("図", 5, 6)]);
    assert(draftCursorAt(text, lines[0], 0) == 0);
    assert(draftCursorAt(text, lines[0], 3) == 1);
    assert(draftCursorAt(text, lines[0], 4) == 2);
    assert(draftCursorAt(text, lines[0], 5) == 2);
    assert(draftCursorAt(text, lines[0], 6) == 3);
    assert(draftCursorAt(text, lines[0], 7) == 3);
    assert(draftCursorAt(text, lines[1], 2) == 6);

    foreach (line; lines)
        assert(textWidth(line.text) <= 7);
}

unittest
{
    import std.array : replicate;

    auto text = "a".replicate(86);
    auto lines = draftLines(text, 43);
    auto previousRowCursor = draftCursorAt(text, lines[0], 43);

    assert(previousRowCursor == 42);
    assert(draftCursorRow(lines, previousRowCursor) == 0);
    assert(draftCursorAt(text, lines[1], 43) == 86);

    auto explicitBreak = draftLines("abcd\nxy", 4);
    assert(draftCursorAt("abcd\nxy", explicitBreak[0], 4) == 4);
    assert(draftCursorRow(explicitBreak, 4) == 0);
}
