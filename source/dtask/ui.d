module dtask.ui;

import dtask.model;
import dtask.terminal;
import dtask.theme;
import dtask.widgets;
import dtask.motion;
import dtask.visuals;
import dtask.text : wrapText, textWidth;
import core.time : MonoTime;
import std.algorithm : min, max;
import std.conv : to;
import std.datetime : Date;
import std.process : environment;
import std.string : strip, replace;

private enum Mode { browse, search, edit, descriptionEdit, reader, calendar, confirmDelete, help }

private static immutable tabLabels = ["1 Open", "2 Today", "3 All", "4 Done"];
private static immutable filterValues = ["open", "today", "all", "done"];
private static immutable fieldLabels = ["Title", "Priority", "Due date", "Notes"];
private static immutable priorityLabels = ["low", "normal", "high", "urgent"];

/**
 * Run the mouse/keyboard workspace using an open, loaded store and a validated palette.
 * Owns and restores the terminal, but leaves store ownership with the caller.
 * themePath is used for reload; empty reloads the built-in palette. Task mutations
 * persist immediately, except editor drafts, which persist only on Save.
 * Returns on quit/interrupt; terminal setup, rendering and I/O failures propagate.
 */
void runUI(TaskStore store, Theme theme, string themePath)
{
    auto terminal = new Terminal();
    scope (exit) terminal.close();

    auto workspace = new Workspace(store, terminal, theme, themePath);
    workspace.run();
}

/*
 * The list is a sorted projection of the store. A drag captures the stable ID
 * on press, previews without mutation, then commits only on a valid release.
 * Editor fields are a separate draft, including calendar and preset changes.
 */
private final class Workspace
{
    TaskStore store;
    Terminal terminal;
    Theme theme;
    string themePath;
    Mode mode;
    string filter = "open";
    string query;
    string previousQuery;
    string status = "Drag a task to a date, or select it and click a date.";
    size_t[] visible;
    int selected;
    int offset;
    int columns;
    int rows;
    int listWidth;
    int listHeight;
    bool running = true;
    bool editing;
    ulong editingId;
    ulong deletingId;
    string[4] fields;
    size_t[4] cursors;
    size_t searchCursor;
    int field;
    int helpOffset;
    int helpLength;
    ulong descriptionId;
    int descriptionOffset;
    int draftOffset;
    bool followDraftCursor = true;
    int caretX;
    int caretY;
    ulong dragId;
    int pressX;
    int pressY;
    bool dragging;
    int dropTarget = -1;
    Date calendarMonth;
    bool calendarDraft;
    ulong calendarId;
    Motion motion;
    long visualTime;
    string[] paintedRows;
    string[] previousRows;
    int paintedColumns;
    int paintedHeight;
    double[ulong] focusFrom;
    double[6] scheduleFrom = [0, 0, 0, 0, 0, 0];

    this(TaskStore store, Terminal terminal, Theme theme, string themePath)
    {
        this.store = store;
        this.terminal = terminal;
        this.theme = theme;
        this.themePath = themePath;
    }

    void run()
    {
        const origin = MonoTime.currTime;
        motion.enabled = environment.get("DTASK_REDUCED_MOTION", "") != "1";
        motion.start(0);
        bool dirty = true;
        uint lastFrame;

        while (running)
        {
            terminal.size(columns, rows);
            visualTime = (MonoTime.currTime - origin).total!"msecs";
            const animate = mode != Mode.edit && mode != Mode.descriptionEdit
                && mode != Mode.search && mode != Mode.help;

            if (dirty)
            {
                refresh();
                render();
                dirty = false;
                lastFrame = motion.frame(visualTime);
            }

            auto event = terminal.readEvent(animate ? motion.waitMillis(visualTime) : 100);
            visualTime = (MonoTime.currTime - origin).total!"msecs";

            if (event.key == Key.none)
            {
                auto nextFrame = motion.frame(visualTime);

                if (animate && nextFrame != lastFrame)
                {
                    render(false);
                    lastFrame = nextFrame;
                }

                continue;
            }

            auto oldTask = current();
            const oldId = oldTask is null ? 0 : oldTask.id;
            const oldMode = mode;
            const oldStatus = status;
            const oldTarget = dropTarget;
            const oldFilter = filter;
            double[ulong] currentFocus;
            double[6] currentSchedule;

            foreach (index; offset .. min(cast(int) visible.length, offset + listHeight))
            {
                auto id = store.tasks[visible[index]].id;
                currentFocus[id] = focusLevel(id);
            }

            foreach (index; 0 .. 6)
                currentSchedule[index] = scheduleLevel(index);

            try
            {
                handle(event);
            }
            catch (Exception error)
            {
                status = "Error: " ~ error.msg;
            }

            if (!running)
                break;

            refresh();
            auto newTask = current();
            const newId = newTask is null ? 0 : newTask.id;

            if (mode != Mode.edit && mode != Mode.descriptionEdit && mode != Mode.search
                && (oldId != newId || oldMode != mode || oldStatus != status
                    || oldTarget != dropTarget || oldFilter != filter))
            {
                focusFrom = currentFocus;
                scheduleFrom = currentSchedule;
                motion.start(visualTime);
            }

            dirty = true;
        }
    }

    double focusLevel(ulong id)
    {
        auto task = current();
        const target = task !is null && task.id == id ? 1.0 : 0.0;
        const start = focusFrom.get(id, 0.0);
        return start + (target - start) * motion.progress(visualTime);
    }

    double scheduleLevel(int index)
    {
        const target = dragging && dropTarget == index ? 1.0 : 0.0;
        return scheduleFrom[index] + (target - scheduleFrom[index]) * motion.progress(visualTime);
    }

    void refresh(ulong preferId = 0)
    {
        visible = sortedIndices(store.tasks, filter, query);

        if (preferId != 0)
        {
            foreach (index, taskIndex; visible)
            {
                if (store.tasks[taskIndex].id == preferId)
                {
                    selected = cast(int) index;
                    break;
                }
            }
        }

        listHeight = mode == Mode.browse || mode == Mode.search || mode == Mode.confirmDelete
            ? taskListHeight(columns, rows, cast(int) visible.length)
            : max(1, rows - (wideSchedule(columns, rows) ? 12 : 14));
        listWidth = wideSchedule(columns, rows) ? columns - 34 : columns;
        selected = max(0, min(selected, cast(int) visible.length - 1));
        offset = max(0, min(offset, max(0, cast(int) visible.length - listHeight)));

        if (selected < offset)
            offset = selected;
        else if (selected >= offset + listHeight)
            offset = selected - listHeight + 1;

        auto task = current();
        auto id = task is null ? 0 : task.id;

        if (id != descriptionId)
        {
            descriptionId = id;
            descriptionOffset = 0;
        }
    }

    Task* current()
    {
        return visible.length ? &store.tasks[visible[selected]] : null;
    }

    string ink(string color, string text, string surface = "")
    {
        return background(surface.length ? surface : theme.background) ~ foreground(color) ~ text;
    }

    string priorityColor(Priority priority)
    {
        final switch (priority)
        {
            case Priority.urgent: return theme.urgent;
            case Priority.high: return theme.high;
            case Priority.normal: return theme.normal;
            case Priority.low: return theme.low;
        }
    }

    void line(ref string frame, int row, string content)
    {
        auto command = "\x1b[" ~ to!string(row) ~ ";1H"
            ~ background(theme.background) ~ foreground(theme.foreground) ~ content
            ~ background(theme.background) ~ "\x1b[K";
        frame ~= command;
        paintedRows[row - 1] = command;
    }

    void at(ref string frame, int x, int y, string text, int width, string color, string surface = "")
    {
        auto command = "\x1b[" ~ to!string(y) ~ ";" ~ to!string(x) ~ "H"
            ~ ink(color, fit(text, width), surface);
        frame ~= command;
        paintedRows[y - 1] ~= command;
    }

    /*
     * All external text crosses fit(): terminal controls are removed and cell
     * widths are respected. Controls use the same rectangles as hit testing.
     * Compact layouts keep the five date targets above the bottom toolbar.
     */
    void render(bool full = true)
    {
        string frame = "\x1b[?25l";
        paintedRows = new string[rows];
        caretY = 0;
        const resized = paintedColumns != columns || paintedHeight != rows;

        if (resized)
        {
            frame ~= "\x1b[2J";
            full = true;
        }

        if (columns < 48 || rows < 20)
        {
            frame ~= "\x1b[2J";
            line(frame, 1, fit("dtask | terminal too small", max(1, columns - 1)));

            if (rows >= 2)
                line(frame, 2, fit("Resize to 48 x 20 or larger. q quits.", max(1, columns - 1)));

            if (rows >= 3)
                line(frame, rows, "");

            terminal.write("\x1b[?2026h" ~ frame ~ "\x1b[?2026l" ~ reset);
            previousRows = paintedRows;
            paintedColumns = columns;
            paintedHeight = rows;
            return;
        }

        for (int row = 1; row <= rows; ++row)
            line(frame, row, "");

        if (mode == Mode.help)
        {
            renderHelp(frame);
            line(frame, rows, "");
            terminal.write("\x1b[?2026h" ~ frame ~ "\x1b[?2026l" ~ reset);
            previousRows = paintedRows;
            paintedColumns = columns;
            paintedHeight = rows;
            return;
        }

        size_t openCount;
        size_t completedCount;
        size_t overdueCount;

        foreach (task; store.tasks)
        {
            if (task.completed)
                ++completedCount;
            else
            {
                ++openCount;

                if (task.due.length && daysUntil(task.due) < 0)
                    ++overdueCount;
            }
        }

        renderHeader(frame, openCount, completedCount, overdueCount);

        auto task = current();

        if (task !is null)
        {
            auto detail = "  #" ~ to!string(task.id) ~ " / " ~ priorityLabel(task.priority)
                ~ " / " ~ (task.due.length ? task.due : "no date")
                ~ "   " ~ to!string(selected + 1) ~ "/" ~ to!string(visible.length);
            line(frame, 4, ink(theme.muted, fit(detail, columns - 22)));
            at(frame, columns - 10, 4, "[Details]", 9, theme.accent);
        }

        at(frame, columns - 20, 4, motion.enabled ? "[FX:on]" : "[FX:off]", 8,
            motion.enabled ? theme.accent : theme.muted);
        line(frame, 5, ink(theme.muted, fit("", columns), theme.panel));

        foreach (index, label; tabLabels)
        {
            auto active = filterValues[index] == filter;
            at(frame, 3 + cast(int) index * 11, 5, label, 11,
                active ? theme.foreground : theme.muted, active ? theme.selected : theme.panel);
        }

        string searchText;

        if (mode == Mode.search)
        {
            int cursorColumn;
            searchText = "  Search > " ~ editable(query, searchCursor, columns - 22, cursorColumn);
            caretX = 12 + cursorColumn;
            caretY = 6;
        }
        else
            searchText = "  / Search: " ~ (query.length ? query : "all tasks");
        line(frame, 6, ink(mode == Mode.search ? theme.accent : theme.muted, fit(searchText, columns - 10)));
        at(frame, columns - 8, 6, "[Clear]", 7, theme.accent);

        if (mode == Mode.reader)
            renderDescription(frame, descriptionBody(columns, rows), true);
        else if (mode == Mode.descriptionEdit)
            renderDescriptionEditor(frame);
        else if (mode == Mode.calendar)
            renderCalendar(frame);
        else
        {
            if (mode == Mode.edit)
                renderForm(frame);
            else
                renderTasks(frame);

            renderSchedule(frame, false);
        }

        if (mode != Mode.calendar)
        {
            auto separator = "  " ~ repeat("-", columns - 4);
            line(frame, rows - 4, ink(theme.border, fit(separator, columns)));
        }

        string actions;

        if (mode == Mode.descriptionEdit)
            actions = "  [Save] [Back] [Cancel]";
        else if (mode == Mode.reader)
            actions = "  [Edit] [Back]";
        else if (mode == Mode.edit)
            actions = "  [Save] [Cancel] [Pick date]";
        else if (mode == Mode.calendar || mode == Mode.help)
            actions = "  [Back]";
        else if (mode == Mode.confirmDelete)
            actions = "  [Delete] [Cancel]";
        else
            actions = "  [New] [Edit] [Done] [Date] [Del] [Help] [Quit]";

        line(frame, rows - 3, ink(mode == Mode.confirmDelete ? theme.urgent : theme.accent,
            fit(actions, columns)));

        if (mode == Mode.browse || mode == Mode.search)
        {
            at(frame, 3, rows - 3, "[New]", 5, theme.background, theme.accent);
            at(frame, 16, rows - 3, "[Done]", 6, theme.success);
            at(frame, 30, rows - 3, "[Del]", 5, theme.urgent);
        }

        auto statusColor = blend(theme.foreground, theme.muted, motion.progress(visualTime));
        line(frame, rows - 2, ink(status.length >= 6 && status[0 .. 6] == "Error:"
            ? theme.urgent : statusColor, fit("  " ~ status, columns)));

        auto footer = mode == Mode.descriptionEdit ? "  Enter: newline | Tab: back | Esc: cancel"
            : mode == Mode.reader ? "  Wheel/PgUp/PgDn/Home/End | Esc: back"
            : mode == Mode.edit ? (field == 3 ? "  Enter: describe | Tab: field | Esc: cancel"
                : "  Tab: field | Enter: save | Esc: cancel")
            : mode == Mode.calendar ? "  Click a day | Esc: back, no date change"
            : mode == Mode.help ? "  Wheel/Up/Down: scroll | Esc: back"
            : mode == Mode.confirmDelete ? "  Delete task #" ~ to!string(deletingId) ~ "? y / Esc"
            : "  v details | / search | m effects | q quit";
        line(frame, rows - 1, ink(theme.muted, fit(footer, columns), theme.panel));
        line(frame, rows, "");

        /*
         * Input frames remain complete for deterministic interaction feedback.
         * Animation frames repaint only changed rows; no re-sort, clear-screen,
         * or task mutation occurs on a visual tick.
         */
        if (!full)
        {
            frame = "\x1b[?25l";

            foreach (index, commands; paintedRows)
            {
                if (index >= previousRows.length || commands != previousRows[index])
                    frame ~= commands;
            }

            /* Keep a stable completion boundary, even on a zero-change tick. */
            frame ~= paintedRows[$ - 1];
        }

        if (caretY > 0)
            frame ~= "\x1b[" ~ to!string(caretY) ~ ";" ~ to!string(caretX) ~ "H\x1b[?25h";

        terminal.write("\x1b[?2026h" ~ frame ~ "\x1b[?2026l" ~ reset);
        previousRows = paintedRows;
        paintedColumns = columns;
        paintedHeight = rows;
    }

    void renderHeader(ref string frame, size_t openCount, size_t completedCount, size_t overdueCount)
    {
        auto brandColor = blend(theme.foreground, theme.accent, motion.progress(visualTime));
        line(frame, 1, ink(brandColor, fit("  dtask_", columns - 26))
            ~ ink(theme.muted, fit(todayISO() ~ " / " ~ theme.name, 26)));
        auto summary = "  " ~ to!string(openCount) ~ " open   " ~ to!string(overdueCount)
            ~ " overdue   " ~ to!string(completedCount) ~ " done";
        line(frame, 3, ink(theme.muted, fit(summary, columns)));

        if (columns >= 78)
            at(frame, columns - 18, 3, progressMeter(completedCount, store.tasks.length, 16), 16, theme.success);
    }

    void renderTasks(ref string frame)
    {
        at(frame, 3, 7, "TASKS / " ~ to!string(visible.length), listWidth - 25, theme.muted);
        at(frame, listWidth - 21, 7, "PRIORITY", 9, theme.muted);
        at(frame, listWidth - 12, 7, "DUE DATE", 12, theme.muted);

        for (int row = 0; row < listHeight; ++row)
        {
            auto index = offset + row;

            if (index < visible.length)
            {
                auto task = store.tasks[visible[index]];
                auto surface = task.id == dragId && dragging ? theme.panel
                    : blend(theme.background, theme.selected, focusLevel(task.id));
                auto color = task.completed ? theme.muted : theme.foreground;
                auto dueColor = task.due.length && daysUntil(task.due) < 0 && !task.completed
                    ? theme.urgent : theme.muted;
                auto marker = index == selected ? "> " : "  ";
                auto content = ink(mode == Mode.confirmDelete ? theme.urgent : theme.accent, marker, surface)
                    ~ ink(index == selected ? theme.accent : theme.muted, task.completed ? "[x] " : "[ ] ", surface)
                    ~ ink(color, fit(task.title, listWidth - 28), surface)
                    ~ ink(priorityColor(task.priority), fit(" " ~ priorityLabel(task.priority), 9), surface)
                    ~ ink(dueColor, fit(task.due.length ? task.due : "no date", 12), surface);
                line(frame, 8 + row, content);
            }
        }

        if (visible.length == 0)
        {
            auto row = 8 + min(1, max(0, listHeight - 2));
            at(frame, 3, row, query.length ? "No matching tasks." : "A clear runway. Make your next move.",
                listWidth - 4, theme.foreground);

            if (row + 1 < 8 + listHeight)
                at(frame, 3, row + 1, query.length ? "Clear the search or try another view."
                    : "Click New or press n to capture a task.", listWidth - 4, theme.muted);
        }

        auto panel = previewBody();

        if (panel.height > 0 && current() !is null)
            renderDescription(frame, panel, false);
    }

    CellRect previewBody()
    {
        auto available = max(1, rows - (wideSchedule(columns, rows) ? 12 : 14));
        return CellRect(3, 9 + listHeight, listWidth - 4, available - listHeight - 1);
    }

    string[] descriptionLines(int width)
    {
        auto task = current();

        if (task is null)
            return ["No task selected."];

        return wrapText(task.title, width) ~ ["", "DESCRIPTION"]
            ~ wrapText(task.notes.length ? task.notes : "No description yet. Click Edit to add one.", width);
    }

    void scrollDescription(int amount, bool absolute = false)
    {
        auto body = mode == Mode.reader ? descriptionBody(columns, rows) : previewBody();
        auto count = cast(int) descriptionLines(body.width).length;
        descriptionOffset = max(0, min(max(0, count - body.height),
            absolute ? amount : descriptionOffset + amount));
    }

    void renderDescription(ref string frame, CellRect body, bool expanded)
    {
        auto lines = descriptionLines(body.width);
        descriptionOffset = max(0, min(descriptionOffset, max(0, cast(int) lines.length - body.height)));
        auto position = to!string(descriptionOffset + 1) ~ "-"
            ~ to!string(min(cast(int) lines.length, descriptionOffset + body.height))
            ~ "/" ~ to!string(lines.length);

        at(frame, body.x, body.y - 1, expanded ? "TASK DETAILS" : "SELECTED TASK", body.width, theme.accent);

        if (!expanded)
            at(frame, body.x + body.width - 9, body.y - 1, "[Expand]", 8, theme.accent);

        foreach (row; 0 .. body.height)
        {
            auto index = descriptionOffset + row;
            at(frame, body.x, body.y + row, index < lines.length ? lines[index] : "",
                body.width, index < lines.length && lines[index] == "DESCRIPTION"
                    ? theme.accent : theme.foreground, theme.panel);
        }

        /* Inline controls share the heading; full reader controls have their own row. */
        auto controlRow = expanded ? rows - 5 : body.y - 1;
        auto controlX = expanded ? 3 : body.x + 15;
        at(frame, controlX, controlRow, "[Up] [Down] " ~ position,
            expanded ? body.width : body.width - 25, theme.accent);
    }

    void beginReader()
    {
        if (current() is null)
            return;

        mode = Mode.reader;
        clearDrag();
        status = "Read only. Edit opens a separate draft.";
    }

    void beginDescriptionEdit()
    {
        mode = Mode.descriptionEdit;
        field = 3;
        followDraftCursor = true;
        status = "Save task | Back: draft | Cancel: discard";
    }

    void renderDescriptionEditor(ref string frame)
    {
        auto body = descriptionBody(columns, rows);
        auto lines = draftLines(fields[3], body.width - 1);
        auto cursorRow = draftCursorRow(lines, cursors[3]);

        if (followDraftCursor)
        {
            if (cursorRow < draftOffset)
                draftOffset = cursorRow;
            else if (cursorRow >= draftOffset + body.height)
                draftOffset = cursorRow - body.height + 1;
        }

        draftOffset = max(0, min(draftOffset, max(0, cast(int) lines.length - body.height)));
        at(frame, 3, 7, "DESCRIPTION / UNSAVED DRAFT", body.width, theme.accent);

        foreach (row; 0 .. body.height)
        {
            auto index = draftOffset + row;
            string text;

            if (index < lines.length)
            {
                text = lines[index].text;

                if (index == cursorRow)
                {
                    auto points = to!dstring(fields[3]);
                    auto prefix = to!string(points[lines[index].start .. cursors[3]]);
                    caretX = body.x + textWidth(prefix);
                    caretY = body.y + row;
                }
            }

            at(frame, body.x, body.y + row, text, body.width, theme.foreground,
                index == cursorRow ? theme.selected : theme.panel);
        }

        at(frame, 3, rows - 5, "[Up] [Down] " ~ to!string(draftOffset + 1) ~ "-"
            ~ to!string(min(cast(int) lines.length, draftOffset + body.height)) ~ "/"
            ~ to!string(lines.length), body.width, theme.accent);
    }

    void handleDescriptionEdit(Event event)
    {
        auto body = descriptionBody(columns, rows);
        auto lines = draftLines(fields[3], body.width - 1);
        auto row = draftCursorRow(lines, cursors[3]);
        auto points = to!dstring(fields[3]);
        followDraftCursor = true;

        if (event.key == Key.escape)
            cancelEdit();
        else if (event.key == Key.tab)
        {
            mode = Mode.edit;
            status = "Description kept in draft. Save applies; Cancel discards.";
        }
        else if (event.key == Key.enter)
            editText(fields[3], cursors[3], Event(Key.text, "\n"), size_t.max);
        else if (event.key == Key.up || event.key == Key.down)
        {
            auto column = textWidth(to!string(points[lines[row].start .. cursors[3]]));
            auto next = max(0, min(cast(int) lines.length - 1, row + (event.key == Key.up ? -1 : 1)));
            cursors[3] = draftCursorAt(fields[3], lines[next], column);
        }
        else if (event.key == Key.pageUp || event.key == Key.pageDown)
        {
            draftOffset += event.key == Key.pageUp ? -body.height : body.height;
            followDraftCursor = false;
        }
        else
            editText(fields[3], cursors[3], event, size_t.max);
    }

    void renderSchedule(ref string frame, bool calendar)
    {
        auto reference = todayISO();
        const wide = !calendar && wideSchedule(columns, rows);

        if (wide)
            at(frame, columns - 31, 8, "SCHEDULE / DROP HERE", 30, theme.accent);

        foreach (index; 0 .. 6)
        {
            auto cell = scheduleCell(columns, rows, index, calendar);
            const highlighted = dragging && dropTarget == index;
            auto surface = blend(theme.panel, theme.selected, scheduleLevel(index));
            const label = index == 5 && calendar ? "Back" : scheduleLabels[index];
            auto color = highlighted ? theme.success : theme.accent;
            auto title = "[" ~ label ~ "]";
            string due;

            if (index < 5)
                due = normalizeDue(scheduleLabels[index], reference);

            if (wide && index < 5)
            {
                size_t count;

                foreach (task; store.tasks)
                {
                    if (!task.completed && task.due == due)
                        ++count;
                }

                title = (highlighted ? "> " : "  ") ~ label ~ "  (" ~ to!string(count) ~ ")";
            }

            at(frame, cell.x, cell.y, title, cell.width, color, surface);

            if (wide && index < 5)
            {
                at(frame, cell.x, cell.y + 1, "  " ~ (due.length ? due : "Unscheduled"),
                    cell.width, theme.muted, surface);

                if (cell.height == 3)
                    at(frame, cell.x, cell.y + 2, "", cell.width, theme.muted, surface);
            }
        }
    }

    /*
     * Keep the insertion point and its character visible without placing a
     * marker in the text. The terminal draws its own cursor over the cell.
     */
    string editable(string text, size_t cursor, int width, out int cursorColumn)
    {
        auto points = to!dstring(text);
        auto start = cursor;
        auto reserved = cursor < points.length ? max(1, textWidth(to!string(points[cursor]))) : 1;
        cursorColumn = 0;

        while (start > 0)
        {
            auto cells = textWidth(to!string(points[start - 1]));

            if (cursorColumn + cells > width - reserved)
                break;

            cursorColumn += cells;
            --start;
        }

        return to!string(points[start .. $]);
    }

    void renderForm(ref string frame)
    {
        auto width = listWidth;
        at(frame, 3, 8, editing ? "EDIT TASK" : "NEW TASK", width - 4, theme.accent);

        foreach (index, label; fieldLabels)
        {
            auto active = field == index;
            auto surface = active ? theme.selected : theme.panel;
            auto row = 9 + cast(int) index;
            at(frame, 3, row, label ~ ":", 10, active ? theme.accent : theme.muted, surface);

            if (index == 1)
            {
                foreach (priorityIndex, priority; priorityLabels)
                {
                    auto chosen = fields[1] == priority;
                    at(frame, 13 + cast(int) priorityIndex * 8, row, "[" ~ priority ~ "]", 8,
                        chosen ? theme.success : theme.muted, chosen ? theme.selected : surface);
                }
            }
            else if (index == 3)
                at(frame, 13, row, "[Edit description]", width - 14, theme.accent, surface);
            else
            {
                auto budget = width - (index == 2 ? 28 : 14);
                string text = fields[index];

                if (active)
                {
                    int cursorColumn;
                    text = editable(fields[index], cursors[index], budget, cursorColumn);
                    caretX = 13 + cursorColumn;
                    caretY = row;
                }

                at(frame, 13, row, text, budget, theme.foreground, surface);

                if (index == 2)
                    at(frame, width - 14, row, "[Pick date]", 12, theme.accent, surface);
            }
        }

        at(frame, 3, 13, "[Save]   [Cancel]", 18, theme.accent);

        if (listHeight > 8)
        {
            at(frame, 3, 15, "Description: Enter opens multiline editing.", width - 4, theme.muted);
            at(frame, 3, 16, "Text: Left/Right, Home/End, Delete, Ctrl-U to clear.", width - 4, theme.muted);
        }
    }

    void renderCalendar(ref string frame)
    {
        static immutable months = ["January", "February", "March", "April", "May", "June", "July", "August",
            "September", "October", "November", "December"];
        at(frame, 3, 7, "[Prev]", 6, theme.accent);
        at(frame, 10, 7, months[calendarMonth.month - 1] ~ " " ~ to!string(calendarMonth.year), 20,
            theme.foreground);
        at(frame, 31, 7, "[Next]", 6, theme.accent);
        at(frame, 39, 7, "[Back]", 6, theme.accent);

        auto selectedDue = calendarDraft ? fields[2] : "";

        if (!calendarDraft)
        {
            foreach (task; store.tasks)
            {
                if (task.id == calendarId)
                    selectedDue = task.due;
            }
        }

        static immutable weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

        foreach (column, weekday; weekdays)
            at(frame, 3 + cast(int) column * 6, 8, weekday, 5, theme.muted);

        foreach (row; 0 .. 6)
        {
            foreach (column; 0 .. 7)
            {
                auto day = calendarDay(calendarMonth, column, row);

                if (day == 0)
                    continue;

                auto iso = calendarISO(calendarMonth, day);
                auto chosen = selectedDue == iso;
                auto label = "[" ~ (day < 10 ? " " : "") ~ to!string(day) ~ "]";
                at(frame, 3 + column * 6, 9 + row, label, 5,
                    iso == todayISO() ? theme.success : theme.foreground,
                    chosen ? theme.selected : theme.panel);
            }
        }

        renderSchedule(frame, true);
    }

    void renderHelp(ref string frame)
    {
        static immutable left = [
            HelpRow("", "NAVIGATE", true),
            HelpRow("j / k, arrows", "Select a task"),
            HelpRow("PgUp / PgDn", "Move one page"),
            HelpRow("Home / End", "First or last task"),
            HelpRow("1 / 2 / 3 / 4", "Open / Today / All / Done"),
            HelpRow("/", "Search titles and notes"),
            HelpRow("Esc", "Cancel or clear search"),
            HelpRow("", ""),
            HelpRow("", "TASKS", true),
            HelpRow("n", "New task"),
            HelpRow("e / Enter", "Edit selected task"),
            HelpRow("v / Details", "Read the full description"),
            HelpRow("Space", "Complete or reopen"),
            HelpRow("p", "Cycle priority"),
            HelpRow("d", "Delete with confirmation"),
            HelpRow("", ""),
            HelpRow("", "MOUSE", true),
            HelpRow("Click a row", "Select a task"),
            HelpRow("Checkbox", "Complete or reopen"),
            HelpRow("Drag to date", "Schedule the task"),
            HelpRow("Wheel", "Scroll the current view"),
            HelpRow("Esc / resize", "Cancel a drag without changes")
        ];
        static immutable right = [
            HelpRow("", "EDIT & WRITE", true),
            HelpRow("Tab", "Next field; back from notes"),
            HelpRow("Enter", "Save fields; newline in notes"),
            HelpRow("Left / Right", "Move the text cursor"),
            HelpRow("Home / End", "Start or end of text"),
            HelpRow("Backspace / Del", "Remove text at the cursor"),
            HelpRow("Ctrl-U", "Clear the current field"),
            HelpRow("Save", "Apply the task draft"),
            HelpRow("Back", "Keep notes in the draft"),
            HelpRow("Cancel / Esc", "Discard the task draft"),
            HelpRow("", ""),
            HelpRow("", "DATES", true),
            HelpRow("Calendar", "Pick a specific day"),
            HelpRow("today / tomorrow", "Schedule a nearby day"),
            HelpRow("next week", "Next Monday"),
            HelpRow("weekend", "Nearest Saturday"),
            HelpRow("+7d", "Seven days from today"),
            HelpRow("none", "Remove the due date"),
            HelpRow("", ""),
            HelpRow("", "WORKSPACE", true),
            HelpRow("m / FX", "Toggle motion effects"),
            HelpRow("r", "Reload the theme"),
            HelpRow("q / Ctrl-C", "Quit dtask")
        ];

        const wide = columns >= 96;
        const width = min(columns - 4, 116);
        const x = (columns - width) / 2 + 1;
        const columnWidth = wide ? (width - 4) / 2 : width;
        const height = rows - 9;
        auto first = wrapHelpRows(wide ? left : left ~ [HelpRow("", "")] ~ right, columnWidth);
        auto second = wide ? wrapHelpRows(right, columnWidth) : null;

        if (wide)
            alignHelpColumns(first, second);

        helpLength = cast(int) max(first.length, second.length);
        scrollHelp(0);

        at(frame, x, 2, "HELP / KEYBOARD & MOUSE", width, theme.foreground);
        at(frame, x, 3, "Shortcuts for your workspace. Esc: back.", width, theme.muted);

        foreach (column; 0 .. (wide ? 2 : 1))
        {
            auto content = column == 0 ? first : second;
            const start = x + column * (columnWidth + 4);

            foreach (row; 0 .. height)
            {
                const index = helpOffset + row;

                if (index >= content.length)
                    continue;

                auto entry = content[index];

                if (entry.heading)
                    at(frame, start, 5 + row, entry.text, columnWidth, theme.foreground, theme.panel);
                else
                {
                    at(frame, start, 5 + row, entry.key, helpKeyWidth, theme.accent);
                    at(frame, start + helpKeyWidth, 5 + row, entry.text,
                        columnWidth - helpKeyWidth, theme.foreground);
                }
            }
        }

        line(frame, rows - 4, ink(theme.border, fit("  " ~ repeat("-", columns - 4), columns)));
        line(frame, rows - 3, ink(theme.accent, "  [Back]  [Up] [Down]"));
        auto position = to!string(helpOffset + 1) ~ "-"
            ~ to!string(min(helpLength, helpOffset + height)) ~ " / " ~ to!string(helpLength);
        line(frame, rows - 2, ink(theme.muted, fit("  " ~ position ~ " lines", columns)));
        line(frame, rows - 1, ink(theme.muted,
            fit("  Arrows: scroll | PgUp/PgDn: page | Home/End", columns), theme.panel));
    }

    void scrollHelp(int amount, bool absolute = false)
    {
        helpOffset = max(0, min(max(0, helpLength - (rows - 9)),
            absolute ? amount : helpOffset + amount));
    }

    void beginEdit(bool existing)
    {
        auto task = current();

        if (existing && task is null)
            return;

        editing = existing;
        editingId = existing ? task.id : 0;
        fields = existing ? [task.title, priorityLabel(task.priority), task.due, task.notes]
            : ["", "normal", "", ""];

        foreach (index, text; fields)
            cursors[index] = to!dstring(text).length;

        field = 0;
        draftOffset = 0;
        mode = Mode.edit;
        status = "Draft only. Click Save or Cancel. Ctrl-U clears.";
    }

    void saveForm()
    {
        auto priority = parsePriority(fields[1].strip);
        auto due = normalizeDue(fields[2].strip, todayISO());
        ulong id = editingId;

        if (editing)
            store.update(id, fields[0], priority, due, fields[3]);
        else
            id = store.add(fields[0], priority, due, fields[3]);

        mode = Mode.browse;
        status = "Saved task #" ~ to!string(id) ~ ".";
        refresh(id);
    }

    void cancelEdit()
    {
        mode = Mode.browse;
        status = "Edit cancelled. Nothing saved.";
    }

    void beginCalendar()
    {
        calendarDraft = mode == Mode.edit;
        auto task = current();

        if (!calendarDraft && task is null)
            return;

        calendarId = calendarDraft ? editingId : task.id;
        auto date = todayISO();
        status = calendarDraft ? "Choose a draft date; Save in the editor to apply." : "Click a day to schedule.";

        try
        {
            auto due = normalizeDue(calendarDraft ? fields[2] : task.due, date);

            if (due.length)
                date = due;
        }
        catch (Exception error)
        {
            /*
             * A partially typed date must not trap the user outside the picker.
             * Keep the draft intact until they choose a valid replacement.
             */
            status = "Invalid draft date: " ~ error.msg ~ " Choose a day to replace it.";
        }

        calendarMonth = Date(to!int(date[0 .. 4]), to!int(date[5 .. 7]), 1);
        mode = Mode.calendar;
    }

    void closeCalendar()
    {
        mode = calendarDraft ? Mode.edit : Mode.browse;
        status = "Calendar closed.";
    }

    void schedule(ulong id, string due)
    {
        foreach (task; store.tasks)
        {
            if (task.id == id)
            {
                store.update(id, task.title, task.priority, due, task.notes);
                status = "Task #" ~ to!string(id) ~ ": " ~ (due.length ? due : "No date") ~ ".";
                refresh(id);
                return;
            }
        }
    }

    void chooseDate(string due)
    {
        if (mode == Mode.edit || (mode == Mode.calendar && calendarDraft))
        {
            fields[2] = due;
            cursors[2] = to!dstring(due).length;
            mode = Mode.edit;
            field = 2;
            status = "Draft date: " ~ (due.length ? due : "No date") ~ ". Save to apply.";
        }
        else
        {
            const task = current();
            auto id = mode == Mode.calendar ? calendarId : task is null ? 0 : task.id;
            mode = Mode.browse;

            if (id != 0)
                schedule(id, due);
        }
    }

    void clearDrag()
    {
        dragId = 0;
        dragging = false;
        dropTarget = -1;
    }

    /* Cursor indices count Unicode code points, never partial UTF-8 bytes. */
    void editText(ref string text, ref size_t cursor, Event event, size_t limit)
    {
        auto points = to!dstring(text);

        switch (event.key)
        {
            case Key.left: if (cursor > 0) --cursor; break;
            case Key.right: if (cursor < points.length) ++cursor; break;
            case Key.home: cursor = 0; break;
            case Key.end: cursor = points.length; break;
            case Key.backspace:
                if (cursor > 0)
                {
                    points = points[0 .. cursor - 1] ~ points[cursor .. $];
                    --cursor;
                }
                break;
            case Key.deleteKey:
                if (cursor < points.length)
                    points = points[0 .. cursor] ~ points[cursor + 1 .. $];
                break;
            case Key.text:
                if (event.text == "\x15")
                {
                    points = ""d;
                    cursor = 0;
                }
                else if (text.length + event.text.length <= limit)
                {
                    auto input = event.text;

                    if (event.pasted)
                    {
                        input = input.replace("\r\n", "\n").replace("\r", "\n");

                        if (mode != Mode.descriptionEdit)
                            input = input.replace("\n", " ").replace("\t", " ");
                    }

                    const inserted = to!dstring(input);
                    points = points[0 .. cursor] ~ inserted ~ points[cursor .. $];
                    cursor += inserted.length;
                }
                break;
            default: break;
        }

        text = to!string(points);
    }

    void handle(Event event)
    {
        if (event.key == Key.interrupt)
        {
            running = false;
            return;
        }

        if (event.key == Key.resize)
        {
            followDraftCursor = true;
            if (dragId != 0)
                status = "Drag cancelled by resize.";

            clearDrag();
            return;
        }

        if (event.key == Key.none)
            return;

        if (event.pasted && mode != Mode.edit && mode != Mode.descriptionEdit && mode != Mode.search)
            return;

        if (columns < 48 || rows < 20)
        {
            if (event.key == Key.text && event.text == "q")
                running = false;

            return;
        }

        if (dragId != 0 && event.key != Key.mouse)
        {
            clearDrag();
            status = "Drag cancelled.";

            if (event.key == Key.escape)
                return;
        }

        if (event.key == Key.mouse)
        {
            handleMouse(event);
            return;
        }

        if (mode == Mode.descriptionEdit)
        {
            handleDescriptionEdit(event);
            return;
        }

        if (mode == Mode.reader)
        {
            if (event.key == Key.escape || (event.key == Key.text && event.text == "v"))
                mode = Mode.browse;
            else if (event.key == Key.enter || (event.key == Key.text && event.text == "e"))
                beginEdit(true);
            else if (event.key == Key.home)
                scrollDescription(0, true);
            else if (event.key == Key.end)
                scrollDescription(int.max, true);
            else if (event.key == Key.up || event.key == Key.down)
                scrollDescription(event.key == Key.up ? -1 : 1);
            else if (event.key == Key.pageUp || event.key == Key.pageDown)
                scrollDescription(event.key == Key.pageUp ? -(rows - 13) : rows - 13);

            return;
        }

        if (mode == Mode.edit)
        {
            if (event.key == Key.escape)
                cancelEdit();
            else if (event.key == Key.enter)
            {
                if (field == 3)
                    beginDescriptionEdit();
                else
                    saveForm();
            }
            else if (event.key == Key.tab || event.key == Key.down)
                field = (field + 1) % 4;
            else if (event.key == Key.up)
                field = (field + 3) % 4;
            else if (field == 3)
            {
                beginDescriptionEdit();
                handleDescriptionEdit(event);
            }
            else
                editText(fields[field], cursors[field], event, 4096);

            return;
        }

        if (mode == Mode.calendar)
        {
            if (event.key == Key.escape)
                closeCalendar();
            else if (event.key == Key.left || event.key == Key.pageUp)
                calendarMonth = adjacentMonth(calendarMonth, -1);
            else if (event.key == Key.right || event.key == Key.pageDown)
                calendarMonth = adjacentMonth(calendarMonth, 1);

            return;
        }

        if (mode == Mode.confirmDelete)
        {
            if (event.key == Key.text && event.text == "y")
                deleteConfirmed();
            else if (event.key == Key.escape || event.key == Key.text)
            {
                mode = Mode.browse;
                status = "Delete cancelled.";
            }

            return;
        }

        if (mode == Mode.help)
        {
            if (event.key == Key.escape || (event.key == Key.text && (event.text == "?" || event.text == "q")))
                mode = Mode.browse;
            else if (event.key == Key.down || event.key == Key.up)
                scrollHelp(event.key == Key.down ? 1 : -1);
            else if (event.key == Key.pageDown || event.key == Key.pageUp)
                scrollHelp(event.key == Key.pageDown ? rows - 9 : -(rows - 9));
            else if (event.key == Key.home || event.key == Key.end)
                scrollHelp(event.key == Key.home ? 0 : int.max, true);

            return;
        }

        if (mode == Mode.search)
        {
            if (event.key == Key.escape)
            {
                query = previousQuery;
                mode = Mode.browse;
            }
            else if (event.key == Key.enter)
                mode = Mode.browse;
            else
                editText(query, searchCursor, event, 1024);

            selected = 0;
            return;
        }

        switch (event.key)
        {
            case Key.up: --selected; return;
            case Key.down: ++selected; return;
            case Key.home: selected = 0; return;
            case Key.end: selected = cast(int) visible.length - 1; return;
            case Key.pageUp: selected -= listHeight; return;
            case Key.pageDown: selected += listHeight; return;
            case Key.enter: beginEdit(true); return;
            case Key.escape: query = ""; status = "Search cleared."; return;
            case Key.text: action(event.text); return;
            default: return;
        }
    }

    void deleteConfirmed()
    {
        store.remove(deletingId);
        mode = Mode.browse;
        status = "Deleted task #" ~ to!string(deletingId) ~ ".";
    }

    void action(string key)
    {
        auto task = current();

        switch (key)
        {
            case "q": running = false; break;
            case "j": ++selected; break;
            case "k": --selected; break;
            case "g": selected = 0; break;
            case "G": selected = cast(int) visible.length - 1; break;
            case "n": beginEdit(false); break;
            case "e": beginEdit(true); break;
            case "v": beginReader(); break;
            case "1": filter = "open"; selected = 0; break;
            case "2": filter = "today"; selected = 0; break;
            case "3": filter = "all"; selected = 0; break;
            case "4": filter = "done"; selected = 0; break;
            case "/":
                previousQuery = query;
                searchCursor = to!dstring(query).length;
                mode = Mode.search;
                break;
            case "?": mode = Mode.help; helpOffset = 0; break;
            case " ":
                if (task !is null)
                {
                    auto id = task.id;
                    store.toggle(id);
                    status = "Updated task #" ~ to!string(id) ~ ".";
                    refresh(id);
                }
                break;
            case "p":
                if (task !is null)
                {
                    auto copy = *task;
                    auto priority = cast(Priority) ((cast(int) copy.priority % 4) + 1);
                    store.update(copy.id, copy.title, priority, copy.due, copy.notes);
                    status = "Priority: " ~ priorityLabel(priority) ~ ".";
                    refresh(copy.id);
                }
                break;
            case "d":
                if (task !is null)
                {
                    deletingId = task.id;
                    mode = Mode.confirmDelete;
                    status = "Deletion is permanent. Click Delete or Cancel.";
                }
                break;
            case "r":
                theme = loadTheme(themePath);
                status = "Theme reloaded: " ~ theme.name ~ ".";
                break;
            case "m":
                motion.enabled = !motion.enabled;
                status = motion.enabled ? "Effects enabled. Editing stays still."
                    : "Reduced motion. Effects disabled for this session.";
                break;
            default: break;
        }
    }

    void handleMouse(Event event)
    {
        const left = (event.button & 3) == 0 && event.button < 64;

        if (mode != Mode.help && left && !event.release && !event.motion && event.y == 4
            && event.x >= columns - 20 && event.x < columns - 12)
        {
            clearDrag();
            action("m");
            return;
        }

        if (dragId != 0 && left)
        {
            if (event.motion)
            {
                dragging = dragging || event.x != pressX || event.y != pressY;
                dropTarget = scheduleHit(columns, rows, event.x, event.y);

                if (dropTarget == 5)
                    dropTarget = -1;

                if (dragging)
                {
                    status = "Drag #" ~ to!string(dragId) ~ " -> " ~ (dropTarget < 0 ? "outside: release cancels"
                        : scheduleLabels[dropTarget] ~ " " ~ normalizeDue(scheduleLabels[dropTarget], todayISO()));
                }

                return;
            }

            if (event.release)
            {
                auto id = dragId;
                const moved = dragging;
                const checkbox = pressX >= 3 && pressX <= 5 && event.x >= 3 && event.x <= 5
                    && event.y == pressY;
                auto target = scheduleHit(columns, rows, event.x, event.y);
                clearDrag();

                if (moved && target >= 0 && target < 5)
                    schedule(id, normalizeDue(scheduleLabels[target], todayISO()));
                else if (moved)
                    status = "Drop cancelled. No date changed.";
                else if (checkbox)
                {
                    store.toggle(id);
                    refresh(id);
                }

                return;
            }
        }

        if (event.release || event.motion)
            return;

        if (event.button == 64 || event.button == 65)
        {
            if (dragId != 0)
                return;

            if (mode == Mode.reader || ((mode == Mode.browse || mode == Mode.search)
                && previewBody().contains(event.x, event.y)))
                scrollDescription(event.button == 64 ? -3 : 3);
            else if (mode == Mode.descriptionEdit)
            {
                draftOffset += event.button == 64 ? -3 : 3;
                followDraftCursor = false;
            }
            else if (mode == Mode.help)
                scrollHelp(event.button == 64 ? -3 : 3);
            else if (mode == Mode.browse || mode == Mode.search)
                selected += event.button == 64 ? -3 : 3;
            else if (mode == Mode.calendar)
                calendarMonth = adjacentMonth(calendarMonth, event.button == 64 ? -1 : 1);

            return;
        }

        if (!left)
            return;

        if (mode == Mode.reader || mode == Mode.descriptionEdit)
        {
            if (event.y == rows - 3)
            {
                if (event.x >= 3 && event.x <= 8)
                {
                    if (mode == Mode.reader)
                        beginEdit(true);
                    else
                        saveForm();
                }
                else if (event.x >= 10 && event.x <= 15)
                {
                    if (mode == Mode.reader)
                        mode = Mode.browse;
                    else
                    {
                        mode = Mode.edit;
                        status = "Description kept in draft. Save applies; Cancel discards.";
                    }
                }
                else if (mode == Mode.descriptionEdit && event.x >= 17 && event.x <= 24)
                    cancelEdit();
            }
            else if (event.y == rows - 5 && event.x >= 3 && event.x <= 13)
            {
                auto amount = event.x < 8 ? -3 : 3;

                if (mode == Mode.reader)
                    scrollDescription(amount);
                else
                {
                    draftOffset += amount;
                    followDraftCursor = false;
                }
            }
            else if (mode == Mode.descriptionEdit && descriptionBody(columns, rows).contains(event.x, event.y))
            {
                auto body = descriptionBody(columns, rows);
                auto lines = draftLines(fields[3], body.width - 1);
                auto row = min(cast(int) lines.length - 1, draftOffset + event.y - body.y);
                cursors[3] = draftCursorAt(fields[3], lines[row], event.x - body.x);
                followDraftCursor = true;
            }

            return;
        }

        if (mode == Mode.confirmDelete)
        {
            if (event.y == rows - 3 && event.x >= 3 && event.x <= 10)
                deleteConfirmed();
            else if (event.y == rows - 3 && event.x >= 12 && event.x <= 19)
            {
                mode = Mode.browse;
                status = "Delete cancelled.";
            }

            return;
        }

        if (mode == Mode.help)
        {
            if (event.y == rows - 3 && event.x >= 3 && event.x <= 8)
                mode = Mode.browse;
            else if (event.y == rows - 3 && event.x >= 11 && event.x <= 14)
                scrollHelp(-3);
            else if (event.y == rows - 3 && event.x >= 16 && event.x <= 21)
                scrollHelp(3);

            return;
        }

        if (mode == Mode.calendar)
        {
            auto preset = scheduleHit(columns, rows, event.x, event.y, true);

            if (preset >= 0 && preset < 5)
                chooseDate(normalizeDue(scheduleLabels[preset], todayISO()));
            else if (preset == 5 || (event.y == 7 && event.x >= 39 && event.x <= 44)
                || (event.y == rows - 3 && event.x >= 3 && event.x <= 8))
                closeCalendar();
            else if (event.y == 7 && event.x >= 3 && event.x <= 8)
                calendarMonth = adjacentMonth(calendarMonth, -1);
            else if (event.y == 7 && event.x >= 31 && event.x <= 36)
                calendarMonth = adjacentMonth(calendarMonth, 1);
            else if (event.y >= 9 && event.y <= 14 && event.x >= 3 && event.x < 44)
            {
                auto column = (event.x - 3) / 6;
                auto day = calendarDay(calendarMonth, column, event.y - 9);

                if (day != 0 && (event.x - 3) % 6 < 5)
                    chooseDate(calendarISO(calendarMonth, day));
            }

            return;
        }

        auto target = scheduleHit(columns, rows, event.x, event.y);

        if (target >= 0)
        {
            if (mode == Mode.search)
                mode = Mode.browse;

            if (target == 5)
                beginCalendar();
            else
                chooseDate(normalizeDue(scheduleLabels[target], todayISO()));

            return;
        }

        if (mode == Mode.edit)
        {
            if (event.y == 13 || event.y == rows - 3)
            {
                const footer = event.y == rows - 3;

                if (event.x >= 3 && event.x <= 8)
                    saveForm();
                else if (event.x >= (footer ? 10 : 12) && event.x <= (footer ? 17 : 19))
                    cancelEdit();
                else if (footer && event.x >= 19 && event.x <= 29)
                    beginCalendar();
            }
            else if (event.y >= 9 && event.y <= 12 && event.x < listWidth)
            {
                field = event.y - 9;

                if (field == 1 && event.x >= 13 && event.x < 45)
                {
                    fields[1] = priorityLabels[(event.x - 13) / 8];
                    cursors[1] = fields[1].length;
                }
                else if (field == 2 && event.x >= listWidth - 14)
                    beginCalendar();
                else if (field == 3)
                    beginDescriptionEdit();
            }

            return;
        }

        if (event.y != 6 && mode == Mode.search)
            mode = Mode.browse;

        auto panel = previewBody();

        if (event.y == 4 && event.x >= columns - 10 && event.x <= columns - 2)
            beginReader();
        else if (panel.height > 0 && event.y == panel.y - 1 && event.x >= panel.x && event.x < panel.x + panel.width)
        {
            if (event.x >= panel.x + panel.width - 9)
                beginReader();
            else if (event.x >= panel.x + 15 && event.x < panel.x + 26)
                scrollDescription(event.x < panel.x + 20 ? -3 : 3);
        }
        else if (event.y == 5 && event.x >= 3 && event.x < 47)
        {
            filter = filterValues[(event.x - 3) / 11];
            selected = 0;
        }
        else if (event.y == 6)
        {
            if (event.x >= columns - 8 && event.x <= columns - 2)
            {
                query = "";
                searchCursor = 0;
                mode = Mode.browse;
                status = "Search cleared.";
            }
            else if (mode != Mode.search)
                action("/");
        }
        else if (event.y >= 8 && event.y < 8 + listHeight && event.x >= 3 && event.x <= listWidth)
        {
            auto index = offset + event.y - 8;

            if (index < visible.length)
            {
                selected = index;
                dragId = store.tasks[visible[index]].id;
                pressX = event.x;
                pressY = event.y;
                dragging = false;
                dropTarget = -1;
            }
        }
        else if (event.y == rows - 3)
        {
            if (event.x >= 3 && event.x <= 7) action("n");
            else if (event.x >= 9 && event.x <= 14) action("e");
            else if (event.x >= 16 && event.x <= 21) action(" ");
            else if (event.x >= 23 && event.x <= 28) beginCalendar();
            else if (event.x >= 30 && event.x <= 34) action("d");
            else if (event.x >= 36 && event.x <= 41) action("?");
            else if (event.x >= 43 && event.x <= 48) action("q");
        }
    }
}

private string repeat(string value, int count)
{
    string result;

    foreach (_; 0 .. max(0, count))
        result ~= value;

    return result;
}
