module dtask.ui;

import dtask.model;
import dtask.terminal;
import dtask.theme;
import dtask.widgets;
import std.algorithm : min, max;
import std.conv : to;
import std.datetime : Date;
import std.string : strip;

private enum Mode { browse, search, edit, calendar, confirmDelete, help }

private static immutable tabLabels = ["1 Open", "2 Today", "3 All", "4 Done"];
private static immutable filterValues = ["open", "today", "all", "done"];
private static immutable fieldLabels = ["Title", "Priority", "Due date", "Notes"];
private static immutable priorityLabels = ["low", "normal", "high", "urgent"];

/// Run the mouse/keyboard workspace using an open, loaded store and a validated palette.
/// Owns and restores the terminal, but leaves store ownership with the caller.
/// themePath is used for reload; empty reloads the built-in palette. Task mutations
/// persist immediately, except editor drafts, which persist only on Save.
/// Returns on quit/interrupt; terminal setup, rendering and I/O failures propagate.
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
    ulong dragId;
    int pressX;
    int pressY;
    bool dragging;
    int dropTarget = -1;
    Date calendarMonth;
    bool calendarDraft;
    ulong calendarId;

    this(TaskStore store, Terminal terminal, Theme theme, string themePath)
    {
        this.store = store;
        this.terminal = terminal;
        this.theme = theme;
        this.themePath = themePath;
    }

    void run()
    {
        while (running)
        {
            terminal.size(columns, rows);
            refresh();
            render();

            auto event = terminal.readEvent();

            while (event.key == Key.none)
                event = terminal.readEvent();

            try
            {
                handle(event);
            }
            catch (Exception error)
            {
                status = "Error: " ~ error.msg;
            }
        }
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

        listHeight = max(1, rows - (wideSchedule(columns, rows) ? 12 : 14));
        listWidth = wideSchedule(columns, rows) ? columns - 34 : columns;
        selected = max(0, min(selected, cast(int) visible.length - 1));
        offset = max(0, min(offset, max(0, cast(int) visible.length - listHeight)));

        if (selected < offset)
            offset = selected;
        else if (selected >= offset + listHeight)
            offset = selected - listHeight + 1;
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
        frame ~= "\x1b[" ~ to!string(row) ~ ";1H"
            ~ background(theme.background) ~ foreground(theme.foreground) ~ content
            ~ background(theme.background) ~ "\x1b[K";
    }

    void at(ref string frame, int x, int y, string text, int width, string color, string surface = "")
    {
        frame ~= "\x1b[" ~ to!string(y) ~ ";" ~ to!string(x) ~ "H" ~ ink(color, fit(text, width), surface);
    }

    /*
     * All external text crosses fit(): terminal controls are removed and cell
     * widths are respected. Controls use the same rectangles as hit testing.
     * Compact layouts keep the five date targets above the bottom toolbar.
     */
    void render()
    {
        string frame = "\x1b[?25l";

        if (columns < 48 || rows < 20)
        {
            frame ~= "\x1b[2J";
            line(frame, 1, fit("dtask | terminal too small", max(1, columns - 1)));

            if (rows >= 2)
                line(frame, 2, fit("Resize to 48 x 20 or larger. q quits.", max(1, columns - 1)));

            if (rows >= 3)
                line(frame, rows, "");

            terminal.write(frame ~ reset);
            return;
        }

        for (int row = 1; row <= rows; ++row)
            line(frame, row, "");

        line(frame, 1, ink(theme.accent, fit("  dtask", columns - 26))
            ~ ink(theme.muted, fit(todayISO() ~ "  /  " ~ theme.name, 26)));
        line(frame, 2, ink(theme.foreground, fit("  A little clarity. A next step.", columns)));

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

        auto summary = "  " ~ to!string(openCount) ~ " open   " ~ to!string(overdueCount)
            ~ " overdue   " ~ to!string(completedCount) ~ " completed";
        line(frame, 3, ink(theme.muted, fit(summary, columns)));

        auto task = current();

        if (task !is null)
        {
            auto detail = "  #" ~ to!string(task.id) ~ " " ~ task.title
                ~ (task.notes.length ? " | " ~ task.notes : "");
            line(frame, 4, ink(theme.muted, fit(detail, columns)));
        }

        foreach (index, label; tabLabels)
        {
            auto active = filterValues[index] == filter;
            at(frame, 3 + cast(int) index * 11, 5, label, 11,
                active ? theme.accent : theme.muted, active ? theme.selected : theme.background);
        }

        auto searchText = mode == Mode.search ? "  Search > " ~ editable(query, searchCursor, columns - 22)
            : "  / Search: " ~ (query.length ? query : "all tasks");
        line(frame, 6, ink(mode == Mode.search ? theme.accent : theme.muted, fit(searchText, columns - 10)));
        at(frame, columns - 8, 6, "[Clear]", 7, theme.accent);

        if (mode == Mode.calendar)
            renderCalendar(frame);
        else
        {
            if (mode == Mode.edit)
                renderForm(frame);
            else if (mode == Mode.help)
                renderHelp(frame);
            else
                renderTasks(frame);

            renderSchedule(frame, false);
        }

        if (mode != Mode.calendar)
            line(frame, rows - 4, ink(theme.border, fit("  " ~ repeat("-", columns - 4), columns)));

        string actions;

        if (mode == Mode.edit)
            actions = "  [Save] [Cancel] [Pick date]";
        else if (mode == Mode.calendar || mode == Mode.help)
            actions = "  [Back]";
        else if (mode == Mode.confirmDelete)
            actions = "  [Delete] [Cancel]";
        else
            actions = "  [New] [Edit] [Done] [Date] [Del] [Help] [Quit]";

        line(frame, rows - 3, ink(theme.accent, fit(actions, columns)));
        line(frame, rows - 2, ink(status.length >= 6 && status[0 .. 6] == "Error:"
            ? theme.urgent : theme.muted, fit("  " ~ status, columns)));

        auto footer = mode == Mode.edit ? "  Tab: field | Enter: save | Esc: cancel"
            : mode == Mode.calendar ? "  Click a day | Esc: back, no date change"
            : mode == Mode.help ? "  Wheel/Up/Down: scroll | Esc: back"
            : mode == Mode.confirmDelete ? "  Delete task #" ~ to!string(deletingId) ~ "? y / Esc"
            : "  Drag to schedule | / search | ? help | q quit";
        line(frame, rows - 1, ink(theme.muted, fit(footer, columns), theme.panel));
        line(frame, rows, "");
        terminal.write(frame ~ reset);
    }

    void renderTasks(ref string frame)
    {
        for (int row = 0; row < listHeight; ++row)
        {
            auto index = offset + row;

            if (index < visible.length)
            {
                auto task = store.tasks[visible[index]];
                auto surface = task.id == dragId && dragging ? theme.panel
                    : index == selected ? theme.selected : theme.background;
                auto color = task.completed ? theme.muted : theme.foreground;
                auto dueColor = task.due.length && daysUntil(task.due) < 0 && !task.completed
                    ? theme.urgent : theme.muted;
                auto content = ink(color, "  ")
                    ~ ink(index == selected ? theme.accent : theme.muted, task.completed ? "[x] " : "[ ] ", surface)
                    ~ ink(color, fit(task.title, listWidth - 28), surface)
                    ~ ink(priorityColor(task.priority), fit(" " ~ priorityLabel(task.priority), 9), surface)
                    ~ ink(dueColor, fit(task.due.length ? task.due : "no date", 12), surface);
                line(frame, 8 + row, content);
            }
            else if (row == 1 && visible.length == 0)
                line(frame, 8 + row, ink(theme.foreground, fit("  Nothing here yet. Click New.", listWidth)));
            else if (row == 2 && visible.length == 0 && query.length)
                line(frame, 8 + row, ink(theme.muted, fit("  Try another search or view.", listWidth)));
        }
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
            auto surface = highlighted ? theme.selected : theme.panel;
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

    string editable(string text, size_t cursor, int width)
    {
        auto points = to!dstring(text);
        auto start = cursor > cast(size_t) max(1, width - 4) ? cursor - max(1, width - 4) : 0;
        return to!string(points[start .. cursor]) ~ "|" ~ to!string(points[cursor .. $]);
    }

    void renderForm(ref string frame)
    {
        auto width = listWidth;
        at(frame, 3, 8, editing ? "EDIT TASK" : "NEW TASK", width - 4, theme.accent);

        foreach (index, label; fieldLabels)
        {
            auto active = field == index;
            auto surface = active ? theme.selected : theme.background;
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
            else
            {
                auto budget = width - (index == 2 ? 28 : 14);
                auto text = active ? editable(fields[index], cursors[index], budget) : fields[index];
                at(frame, 13, row, text, budget, theme.foreground, surface);

                if (index == 2)
                    at(frame, width - 14, row, "[Pick date]", 12, theme.accent, surface);
            }
        }

        at(frame, 3, 13, "[Save]   [Cancel]", 18, theme.accent);

        if (listHeight > 8)
        {
            at(frame, 3, 15, "Click priority or a date. Only Save writes changes.", width - 4, theme.muted);
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
        static immutable lines = [
            "KEYBOARD & MOUSE",
            "Drag a task onto a date section to schedule.",
            "Or select a task and click a date / Calendar.",
            "Outside drop, Esc or resize cancels a drag.",
            "New / Edit: click priority and Pick date.",
            "Save writes the draft; Cancel discards it.",
            "j/k, arrows: select | wheel: scroll",
            "n: new | e / Enter: edit | Space: done",
            "p: priority | d: delete with confirmation",
            "/: search | 1/2/3/4: Open/Today/All/Done",
            "Text: arrows, Home/End, Delete, Ctrl-U",
            "Dates: today, tomorrow, next week, +3d",
            "Next week is next Monday; weekend Saturday.",
            "r: reload theme | q: quit | Esc: back"
        ];

        foreach (row; 0 .. listHeight)
        {
            auto index = row + helpOffset;
            at(frame, 3, 8 + row, index < lines.length ? lines[index] : "", listWidth - 4,
                row == 0 ? theme.accent : theme.foreground);
        }
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
            // A partially typed date must not trap the user outside the picker.
            // Keep the draft intact until they choose a valid replacement.
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

    // Cursor indices count Unicode code points, never partial UTF-8 bytes.
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
                    const inserted = to!dstring(event.text);
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
            if (dragId != 0)
                status = "Drag cancelled by resize.";

            clearDrag();
            return;
        }

        if (event.key == Key.none)
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

        if (mode == Mode.edit)
        {
            if (event.key == Key.escape)
                cancelEdit();
            else if (event.key == Key.enter)
                saveForm();
            else if (event.key == Key.tab || event.key == Key.down)
                field = (field + 1) % 4;
            else if (event.key == Key.up)
                field = (field + 3) % 4;
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
            else if (event.key == Key.down || event.key == Key.pageDown)
                helpOffset = min(max(0, 14 - listHeight), helpOffset + 1);
            else if (event.key == Key.up || event.key == Key.pageUp)
                helpOffset = max(0, helpOffset - 1);

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
            default: break;
        }
    }

    void handleMouse(Event event)
    {
        const left = (event.button & 3) == 0 && event.button < 64;

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

            if (mode == Mode.help)
                helpOffset = max(0, min(max(0, 14 - listHeight), helpOffset + (event.button == 64 ? -1 : 1)));
            else if (mode == Mode.browse || mode == Mode.search)
                selected += event.button == 64 ? -3 : 3;
            else if (mode == Mode.calendar)
                calendarMonth = adjacentMonth(calendarMonth, event.button == 64 ? -1 : 1);

            return;
        }

        if (!left)
            return;

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
            }

            return;
        }

        if (event.y != 6 && mode == Mode.search)
            mode = Mode.browse;

        if (event.y == 5 && event.x >= 3 && event.x < 47)
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
