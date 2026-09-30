module ui_test;

import dtask.widgets;
import std.datetime : Date;

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
    // Every scheduling rectangle remains visible and disjoint at each layout
    // boundary. Hit testing agrees with drawing for every cell, not just labels.
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
    // Every day appears exactly once in the six-row grid, including February
    // and months starting Sunday that need their sixth calendar row.
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
