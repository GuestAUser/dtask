module dtask.visuals;

import dtask.motion : Motion;
import dtask.text : graphemeBoundaries, textWidth;
import dtask.theme : background, foreground, blend;
import std.array : appender;
import std.conv : to;
import std.utf : codeLength;

/**
 * Draw a fitted, printable segment on a solid surface while a glint crosses it.
 * Each cluster gets one foreground blended toward glint, sampled at its center
 * cell. Spaces keep the current color, so padding never shows a moving smear,
 * and adjacent equal levels share one color run. The caller passes the
 * segment's first cell within the swept text and that text's width in cells.
 */
string shimmerInk(string text, string color, string surface, string glint,
    ref const Motion motion, long now, int cell, int width)
{
    enum levels = 16;
    auto output = appender!string();
    output.put(background(surface));

    if (!motion.active(now))
    {
        output.put(foreground(color));
        output.put(text);
        return output.data;
    }

    auto points = to!dstring(text);
    auto boundaries = graphemeBoundaries(points);
    string[levels + 1] inks;
    int previous = -1;
    size_t byteOffset;
    size_t runStart;

    foreach (index; 1 .. boundaries.length)
    {
        const first = boundaries[index - 1];
        const last = boundaries[index];
        const start = byteOffset;

        foreach (point; points[first .. last])
            byteOffset += codeLength!char(point);

        const ascii = last == first + 1 && points[first] < 0x7f;
        const cells = ascii ? 1 : textWidth(text[start .. byteOffset]);

        if (!ascii || points[first] != ' ')
        {
            const level = cast(int) (levels * motion.strength(now, cell + cells * 0.5, width) + 0.5);

            if (level != previous)
            {
                output.put(text[runStart .. start]);

                if (!inks[level].length)
                    inks[level] = foreground(blend(color, glint, level / cast(double) levels));

                output.put(inks[level]);
                runStart = start;
                previous = level;
            }
        }

        cell += cells;
    }

    output.put(text[runStart .. $]);
    return output.data;
}

/**
 * Return how many of width cells a completion bar fills: floor(width * done / total),
 * where done is completed capped at total. Zero tasks or a nonpositive width
 * fill nothing; completed values at or above total fill every cell.
 */
int completedCells(size_t completed, size_t total, int width)
{
    if (width <= 0 || total == 0 || completed == 0)
        return 0;

    if (completed >= total)
        return width;

    /*
     * Count floor(width * completed / total) without an overflowing product.
     * Subtract before adding whenever the next fraction carries. The loop is
     * bounded by the bar width, not the number of tasks.
     */
    int filled;
    size_t remainder;
    const complement = total - completed;

    foreach (_; 0 .. width)
    {
        if (remainder >= complement)
        {
            remainder -= complement;
            ++filled;
        }
        else
        {
            remainder += completed;
        }
    }

    return filled;
}
