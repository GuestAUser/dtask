module dtask.visuals;

/**
 * Return an exact-width contiguous ASCII completion bar: '=' filled, '.' empty.
 * Widths of at least three include square brackets; smaller bars use all cells.
 * Nonpositive widths return an empty string, zero tasks leave the bar empty,
 * and completed values above total saturate at full. Fractions round down.
 */
string progressMeter(size_t completed, size_t total, int width)
{
    if (width <= 0)
    {
        return "";
    }

    auto cells = new char[width];
    cells[] = '.';

    const start = width >= 3 ? 1 : 0;
    const capacity = width >= 3 ? width - 2 : width;
    size_t filled;

    if (total != 0 && completed >= total)
    {
        filled = capacity;
    }
    else if (total != 0 && completed != 0)
    {
        /*
         * Count floor(capacity * completed / total) without an overflowing
         * product. Subtract before adding whenever the next fraction carries.
         * The loop is bounded by the output width, not the number of tasks.
         */
        size_t remainder;
        const complement = total - completed;

        foreach (_; 0 .. capacity)
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
    }

    cells[start .. start + filled] = '=';

    if (width >= 3)
    {
        cells[0] = '[';
        cells[$ - 1] = ']';
    }

    return cast(string) cells;
}
