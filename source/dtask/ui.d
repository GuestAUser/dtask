module dtask.ui;

import dtask.model;
import dtask.terminal;
import dtask.theme;
import dtask.widgets;
import dtask.motion;
import dtask.visuals;
import dtask.text : graphemeBoundaries, wrapText, textWidth;
import core.time : MonoTime;
import std.algorithm : min, max, startsWith;
import std.array : replicate;
import std.conv : to;
import std.datetime : Date;
import std.process : environment;
import std.string : strip, stripRight, replace;

private enum Mode { browse, search, edit, descriptionEdit, reader, calendar, confirmDelete, help }

private static immutable tabLabels = ["1 Open", "2 Today", "3 All", "4 Done"];
private static immutable filterValues = ["open", "today", "all", "done"];
private static immutable fieldLabels = ["Title", "Priority", "Due date", "Notes"];
private static immutable priorityLabels = ["low", "normal", "high", "urgent"];

/*
 * Keep only the displayed description's wrapping. Input frames discard it,
 * while visual-only frames reuse it unless the body's width has changed.
 */
package struct DescriptionWrap
{
    private string[] wrapped;
    private int width;

    version (unittest) size_t computations;

    void beginFrame(bool full)
    {
        if (full)
            wrapped = null;
    }

    string[] lines(const Task* task, int requestedWidth)
    {
        if (wrapped is null || width != requestedWidth)
        {
            wrapped = task is null ? ["No task selected."]
                : wrapText(task.title, requestedWidth) ~ ["", "DESCRIPTION"]
                    ~ wrapText(task.notes.length ? task.notes
                        : "No description yet. Click Edit to add one.", requestedWidth);
            width = requestedWidth;

            version (unittest) ++computations;
        }

        return wrapped;
    }
}

/*
 * A click target registered by the frame that drew it. Drawing and hit testing
 * share one rectangle, so a moved or renamed control can never lose its action.
 */
private struct Control
{
    CellRect area;
    void delegate() action;
}

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
    ulong previousSearchId;
    string status = "Drag a task onto a date to schedule it.";
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
    DescriptionWrap descriptionWrap;
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
    Control[] controls;
    ulong shimmerFocus;
    int shimmerDrop = -1;
    bool shimmerStatus;

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
        bool dirty = true;
        uint lastFrame;

        while (running)
        {
            terminal.size(columns, rows);
            visualTime = (MonoTime.currTime - origin).total!"msecs";
            const animate = motionAllowed();

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

            const oldId = currentId();
            const oldMode = mode;
            const oldStatus = status;
            const oldTarget = dropTarget;
            const oldFilter = filter;
            const oldFields = fields;

            try
            {
                handle(event);

                /* A failed Save describes the old draft, not its next revision. */
                if ((mode == Mode.edit || mode == Mode.descriptionEdit)
                    && fields != oldFields && status.startsWith("Error:"))
                    status = "Editing a draft. Save applies; Esc cancels.";
            }
            catch (Exception error)
            {
                status = "Error: " ~ error.msg;
            }

            if (!running)
                break;

            refresh();
            const newId = currentId();
            const focusChanged = oldId != newId || oldMode != mode || oldFilter != filter;
            const targetChanged = oldTarget != dropTarget;
            const statusChanged = oldStatus != status;

            if (!motionAllowed() || !motion.enabled)
            {
                motion.stop();
            }
            else if (focusChanged || targetChanged || statusChanged)
            {
                /* A live sweep keeps its position and also lights the new targets. */
                if (!motion.active(visualTime))
                {
                    shimmerFocus = 0;
                    shimmerDrop = -1;
                    shimmerStatus = false;
                }

                if (focusChanged)
                    shimmerFocus = newId;

                if (targetChanged)
                    shimmerDrop = dropTarget;

                shimmerStatus = shimmerStatus || statusChanged;
                motion.start(visualTime);
            }

            dirty = true;
        }
    }

    bool motionAllowed() const
    {
        return mode != Mode.edit && mode != Mode.descriptionEdit
            && mode != Mode.search && mode != Mode.help;
    }

    bool browsing() const
    {
        return mode == Mode.browse || mode == Mode.search;
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

        const id = currentId();

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

    ulong currentId()
    {
        auto task = current();
        return task is null ? 0 : task.id;
    }

    /* The stored task with id, or null after it has been deleted. */
    Task* find(ulong id)
    {
        foreach (ref task; store.tasks)
        {
            if (task.id == id)
                return &task;
        }

        return null;
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

    /* Ink fitted text while the active glint sweeps its first extent cells. */
    string shimmer(string fitted, string color, string surface, int extent)
    {
        return shimmerInk(fitted, color, surface, theme.accent, motion, visualTime, 0, extent);
    }

    /* Paint a whole row on the workspace background; frame diffs compare these rows. */
    void line(ref string frame, int row, string content)
    {
        auto command = "\x1b[" ~ to!string(row) ~ ";1H"
            ~ background(theme.background) ~ foreground(theme.foreground) ~ content
            ~ background(theme.background) ~ "\x1b[K";
        frame ~= command;
        paintedRows[row - 1] = command;
    }

    /* Append colored content at a one-based cell and record it with its row. */
    void place(ref string frame, int x, int y, string content)
    {
        auto command = "\x1b[" ~ to!string(y) ~ ";" ~ to!string(x) ~ "H" ~ content;
        frame ~= command;
        paintedRows[y - 1] ~= command;
    }

    void at(ref string frame, int x, int y, string text, int width, string color, string surface = "")
    {
        place(frame, x, y, ink(color, fit(text, width), surface));
    }

    /*
     * Draw a bracketed button and register its action, unless action is null.
     * Labels are internal ASCII, so their byte length is their cell width.
     * Returns the column after the button and its separating space.
     */
    int button(ref string frame, int x, int y, string label, void delegate() action,
        string color = "", string surface = "")
    {
        const text = "[" ~ label ~ "]";
        const width = cast(int) text.length;
        at(frame, x, y, text, width, color.length ? color : theme.accent, surface);

        if (action !is null)
            controls ~= Control(CellRect(x, y, width, 1), action);

        return x + width + 1;
    }

    /* Register a click target for content drawn by other means. */
    void clickable(CellRect area, void delegate() action)
    {
        controls ~= Control(area, action);
    }

    /* Write one synchronized frame, then keep its rows for the next diff. */
    void present(string frame)
    {
        terminal.write("\x1b[?2026h" ~ frame ~ "\x1b[?2026l" ~ reset);
        previousRows = paintedRows;
        paintedColumns = columns;
        paintedHeight = rows;
    }

    /*
     * All external text crosses fit(): terminal controls are removed and cell
     * widths are respected. Controls register the rectangles they draw, so a
     * click always acts on the latest frame. Compact layouts keep the five date
     * targets above the bottom toolbar.
     */
    void render(bool full = true)
    {
        string frame = "\x1b[?25l";
        paintedRows = new string[rows];
        controls = null;
        caretY = 0;

        if (paintedColumns != columns || paintedHeight != rows)
        {
            frame ~= "\x1b[2J";
            full = true;
        }

        descriptionWrap.beginFrame(full);

        if (columns < 48 || rows < 20)
        {
            frame ~= "\x1b[2J";
            line(frame, 1, fit("dtask | terminal too small", max(1, columns - 1)));

            if (rows >= 2)
                line(frame, 2, fit("Resize to 48 x 20 or larger. q quits.", max(1, columns - 1)));

            if (rows >= 3)
                line(frame, rows, "");

            present(frame);
            return;
        }

        for (int row = 1; row <= rows; ++row)
            line(frame, row, "");

        if (mode == Mode.help)
            renderHelp(frame);
        else
        {
            renderWorkspace(frame);
            renderStatus(frame);
        }

        /* The compact calendar places its date presets on this row. */
        if (mode != Mode.calendar)
            line(frame, rows - 4, ink(theme.border, fit("  " ~ replicate("─", columns - 4), columns)));

        renderToolbar(frame);
        line(frame, rows - 1, ink(theme.muted, fit(footer(), columns), theme.panel));
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

        present(frame);
    }

    void renderWorkspace(ref string frame)
    {
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

        if (auto task = current())
        {
            auto detail = "  #" ~ to!string(task.id) ~ " / " ~ priorityLabel(task.priority)
                ~ " / " ~ (task.due.length ? task.due : "no date")
                ~ "   " ~ to!string(selected + 1) ~ "/" ~ to!string(visible.length);
            line(frame, 4, ink(theme.muted, fit(detail, columns - 22)));

            if (browsing)
                button(frame, columns - 10, 4, "Details", &beginReader);
        }

        button(frame, columns - 20, 4, motion.enabled ? "FX:on" : "FX:off", () { action("m"); },
            motion.enabled ? theme.accent : theme.muted);

        line(frame, 5, ink(theme.muted, fit("", columns), theme.panel));

        foreach (index, label; tabLabels)
        {
            const active = filterValues[index] == filter;
            const x = 3 + cast(int) index * 11;
            at(frame, x, 5, label, 11, active ? theme.foreground : theme.muted,
                active ? theme.selected : theme.panel);

            if (browsing)
                clickable(CellRect(x, 5, 11, 1), showFilter(filterValues[index]));
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

        if (browsing)
        {
            /* The row starts a search; its Clear button is registered on top. */
            clickable(CellRect(1, 6, columns, 1), &beginSearch);
            button(frame, columns - 8, 6, "Clear", &clearSearch);
        }

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
    }

    void renderHeader(ref string frame, size_t openCount, size_t completedCount, size_t overdueCount)
    {
        /* Right-align the date and theme to the edge shared by the header buttons. */
        auto context = stripRight(fit(todayISO() ~ " / " ~ theme.name, columns - 12));
        line(frame, 1, ink(theme.accent, fit("  dtask_", columns - 2 - textWidth(context)))
            ~ ink(theme.muted, context));

        line(frame, 3, ink(theme.muted, "  " ~ to!string(openCount) ~ " open   ")
            ~ ink(overdueCount ? theme.urgent : theme.muted, to!string(overdueCount) ~ " overdue")
            ~ ink(theme.muted, "   " ~ to!string(completedCount) ~ " done"));

        if (columns >= 78)
        {
            const filled = completedCells(completedCount, store.tasks.length, 16);
            place(frame, columns - 17, 3, ink(theme.success, replicate("━", filled))
                ~ ink(theme.border, replicate("─", 16 - filled)));
        }
    }

    void renderStatus(ref string frame)
    {
        auto color = status.startsWith("Error:") ? theme.urgent : theme.muted;
        auto text = fit("  " ~ status, columns);
        line(frame, rows - 2, shimmerStatus
            ? shimmer(text, color, theme.background, textWidth(stripRight(text)))
            : ink(color, text));
    }

    void renderToolbar(ref string frame)
    {
        const y = rows - 3;
        int x = 3;

        final switch (mode)
        {
            case Mode.browse:
            case Mode.search:
                x = button(frame, x, y, "New", () { action("n"); }, theme.background, theme.accent);
                x = button(frame, x, y, "Edit", () { action("e"); });
                x = button(frame, x, y, "Done", () { action(" "); }, theme.success);
                x = button(frame, x, y, "Date", &beginCalendar);
                x = button(frame, x, y, "Del", () { action("d"); }, theme.urgent);
                x = button(frame, x, y, "Help", () { action("?"); });
                button(frame, x, y, "Quit", () { action("q"); });
                break;
            case Mode.edit:
                x = button(frame, x, y, "Save", &saveForm);
                x = button(frame, x, y, "Cancel", &cancelEdit);
                button(frame, x, y, "Pick date", &pickDraftDate);
                break;
            case Mode.descriptionEdit:
                x = button(frame, x, y, "Save", &saveForm);
                x = button(frame, x, y, "Back", &keepDraft);
                button(frame, x, y, "Cancel", &cancelEdit);
                break;
            case Mode.reader:
                x = button(frame, x, y, "Edit", () { beginEdit(true); });
                button(frame, x, y, "Back", &closeReader);
                break;
            case Mode.calendar:
                button(frame, x, y, "Back", &closeCalendar);
                break;
            case Mode.confirmDelete:
                x = button(frame, x, y, "Delete", &deleteConfirmed, theme.urgent);
                button(frame, x, y, "Cancel", &cancelDelete);
                break;
            case Mode.help:
                x = button(frame, x, y, "Back", &closeHelp);
                x = button(frame, x, y, "Up", scrollAction(-3));
                button(frame, x, y, "Down", scrollAction(3));
                break;
        }
    }

    string footer()
    {
        final switch (mode)
        {
            case Mode.browse:
            case Mode.search:
                return "  v details | / search | m effects | q quit";
            case Mode.edit:
                return field == 3 ? "  Enter: describe | Tab: field | Esc: cancel"
                    : "  Tab: field | Enter: save | Esc: cancel";
            case Mode.descriptionEdit:
                return "  Enter: newline | Tab: back | Esc: cancel";
            case Mode.reader:
                return "  Wheel/PgUp/PgDn/Home/End | Esc: back";
            case Mode.calendar:
                return "  Click a day | Esc: back, no date change";
            case Mode.confirmDelete:
                return "  Delete task #" ~ to!string(deletingId) ~ "? y / Esc";
            case Mode.help:
                return "  Arrows: scroll | PgUp/PgDn: page | Home/End";
        }
    }

    void renderTasks(ref string frame)
    {
        at(frame, 3, 7, "TASKS / " ~ to!string(visible.length), listWidth - 25, theme.muted);
        at(frame, listWidth - 21, 7, "PRIORITY", 9, theme.muted);
        at(frame, listWidth - 12, 7, "DUE DATE", 12, theme.muted);

        /*
         * Columns: marker, checkbox, title and a one-cell gap, then the nine-cell
         * priority and twelve-cell due-date fields that mouse presses open.
         */
        for (int row = 0; row < listHeight; ++row)
        {
            const index = offset + row;

            if (index >= visible.length)
                break;

            auto task = store.tasks[visible[index]];
            const chosen = index == selected;
            auto surface = task.id == dragId && dragging ? theme.panel
                : chosen ? theme.selected : theme.background;
            auto color = task.completed ? theme.muted : theme.foreground;
            auto dueColor = task.due.length && daysUntil(task.due) < 0 && !task.completed
                ? theme.urgent : theme.muted;
            auto title = elide(task.title, listWidth - 29) ~ " ";

            line(frame, 8 + row,
                ink(mode == Mode.confirmDelete ? theme.urgent : theme.accent, chosen ? "> " : "  ", surface)
                ~ ink(chosen ? theme.accent : theme.muted, task.completed ? "[x] " : "[ ] ", surface)
                ~ (chosen && task.id == shimmerFocus
                    ? shimmer(title, color, surface, textWidth(stripRight(title)))
                    : ink(color, title, surface))
                ~ ink(priorityColor(task.priority), fit(priorityLabel(task.priority), 9), surface)
                ~ ink(dueColor, fit(task.due.length ? task.due : "no date", 12), surface));
        }

        if (visible.length == 0)
        {
            string headline = "A clear runway. Make your next move.";
            string hint = "Click New or press n to capture a task.";

            if (query.length)
            {
                headline = "No matching tasks.";
                hint = "Clear the search or try another view.";
            }
            else if (filter == "done")
            {
                headline = "Nothing completed yet.";
                hint = "Completed tasks appear here.";
            }
            else if (filter == "today")
            {
                headline = "Nothing due today.";
                hint = "Overdue and due-today tasks appear here.";
            }

            const row = 8 + min(1, max(0, listHeight - 2));
            at(frame, 3, row, headline, listWidth - 4, theme.foreground);

            if (row + 1 < 8 + listHeight)
                at(frame, 3, row + 1, hint, listWidth - 4, theme.muted);
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
        return descriptionWrap.lines(current(), width);
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
        const interactive = expanded || browsing;

        at(frame, body.x, body.y - 1, expanded ? "TASK DETAILS" : "SELECTED TASK", body.width, theme.accent);

        if (!expanded)
            button(frame, body.x + body.width - 9, body.y - 1, "Expand", interactive ? &beginReader : null);

        foreach (row; 0 .. body.height)
        {
            auto index = descriptionOffset + row;
            at(frame, body.x, body.y + row, index < lines.length ? lines[index] : "",
                body.width, index < lines.length && lines[index] == "DESCRIPTION"
                    ? theme.accent : theme.foreground, theme.panel);
        }

        /* Inline controls share the heading; full reader controls have their own row. */
        const y = expanded ? rows - 5 : body.y - 1;
        auto x = button(frame, expanded ? 3 : body.x + 15, y, "Up", interactive ? scrollAction(-3) : null);
        x = button(frame, x, y, "Down", interactive ? scrollAction(3) : null);
        at(frame, x, y, position, expanded ? body.width - 12 : body.width - 37, theme.muted);
    }

    void beginReader()
    {
        if (current() is null)
            return;

        mode = Mode.reader;
        clearDrag();
        status = "Read only. Edit opens a separate draft.";
    }

    void closeReader()
    {
        mode = Mode.browse;
    }

    void beginDescriptionEdit()
    {
        mode = Mode.descriptionEdit;
        field = 3;
        followDraftCursor = true;
        status = "Save task | Back: draft | Cancel: discard";
    }

    void keepDraft()
    {
        mode = Mode.edit;
        status = "Notes kept in the draft. Save to apply.";
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

        auto position = to!string(draftOffset + 1) ~ "-"
            ~ to!string(min(cast(int) lines.length, draftOffset + body.height)) ~ "/"
            ~ to!string(lines.length);
        auto x = button(frame, 3, rows - 5, "Up", scrollAction(-3));
        x = button(frame, x, rows - 5, "Down", scrollAction(3));
        at(frame, x, rows - 5, position, body.width - 12, theme.muted);
    }

    void scrollDraft(int amount)
    {
        draftOffset += amount;
        followDraftCursor = false;
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
            keepDraft();
        else if (event.key == Key.enter)
            editText(fields[3], cursors[3], Event(Key.text, "\n"), size_t.max);
        else if (event.key == Key.up || event.key == Key.down)
        {
            auto column = textWidth(to!string(points[lines[row].start .. cursors[3]]));
            auto next = max(0, min(cast(int) lines.length - 1, row + (event.key == Key.up ? -1 : 1)));
            cursors[3] = draftCursorAt(fields[3], lines[next], column);
        }
        else if (event.key == Key.pageUp || event.key == Key.pageDown)
            scrollDraft(event.key == Key.pageUp ? -body.height : body.height);
        else
            editText(fields[3], cursors[3], event, size_t.max);
    }

    /* Move the draft cursor to a clicked cell, clamped to that visual row. */
    void placeDraftCaret(int x, int y)
    {
        auto body = descriptionBody(columns, rows);
        auto lines = draftLines(fields[3], body.width - 1);
        auto row = min(cast(int) lines.length - 1, draftOffset + y - body.y);
        cursors[3] = draftCursorAt(fields[3], lines[row], x - body.x);
        followDraftCursor = true;
    }

    void renderSchedule(ref string frame, bool calendar)
    {
        auto reference = todayISO();
        const wide = !calendar && wideSchedule(columns, rows);
        const interactive = calendar || browsing || mode == Mode.edit;

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

            auto fitted = fit(title, cell.width);
            place(frame, cell.x, cell.y, highlighted && shimmerDrop == index
                ? shimmer(fitted, color, surface, textWidth(title)) : ink(color, fitted, surface));

            if (wide && index < 5)
            {
                at(frame, cell.x, cell.y + 1, "  " ~ (due.length ? due : "Unscheduled"),
                    cell.width, theme.muted, surface);

                if (cell.height == 3)
                    at(frame, cell.x, cell.y + 2, "", cell.width, theme.muted, surface);
            }

            if (interactive)
                clickable(cell, scheduleAction(index, calendar));
        }
    }

    /*
     * Keep the insertion point and its character visible without placing a
     * marker in the text. The terminal draws its own cursor over the cell.
     */
    string editable(string text, size_t cursor, int width, out int cursorColumn)
    {
        auto points = to!dstring(text);
        auto boundaries = graphemeBoundaries(points);
        size_t boundary;

        while (boundaries[boundary] < cursor)
            ++boundary;

        auto start = cursor;
        auto reserved = cursor < points.length
            ? max(1, textWidth(to!string(points[cursor .. boundaries[boundary + 1]]))) : 1;
        cursorColumn = 0;

        while (boundary > 0)
        {
            auto previous = boundaries[boundary - 1];
            auto cells = textWidth(to!string(points[previous .. start]));

            if (cursorColumn + cells > width - reserved)
                break;

            cursorColumn += cells;
            start = previous;
            --boundary;
        }

        return to!string(points[start .. $]);
    }

    void renderForm(ref string frame)
    {
        auto width = listWidth;

        if (field == 1)
        {
            int cursorColumn;
            auto text = editable(fields[1], cursors[1], width - 15, cursorColumn);
            at(frame, 3, 7, "Priority > ", 11, theme.accent);
            at(frame, 14, 7, text, width - 15, theme.foreground, theme.selected);
            caretX = 14 + cursorColumn;
            caretY = 7;
        }

        at(frame, 3, 8, editing ? "EDIT TASK" : "NEW TASK", width - 4, theme.accent);

        foreach (index, label; fieldLabels)
        {
            const active = field == index;
            auto surface = active ? theme.selected : theme.panel;
            const row = 9 + cast(int) index;

            /* Each field is one even bar, and a press anywhere on it focuses the field. */
            at(frame, 3, row, label ~ ":", width - 4, active ? theme.accent : theme.muted, surface);
            clickable(CellRect(1, row, width - 1, 1), focusField(cast(int) index));

            if (index == 1)
            {
                auto x = 13;

                foreach (priority; priorityLabels)
                {
                    const chosen = fields[1] == priority;
                    x = button(frame, x, row, priority, choosePriority(priority),
                        chosen ? theme.success : theme.muted, chosen ? theme.selected : surface);
                }
            }
            else if (index == 3)
                button(frame, 13, row, "Edit description", &beginDescriptionEdit, theme.accent, surface);
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
                    button(frame, width - 14, row, "Pick date", &pickDraftDate, theme.accent, surface);
            }
        }

        auto x = button(frame, 3, 13, "Save", &saveForm);
        button(frame, x, 13, "Cancel", &cancelEdit);

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
        static immutable weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

        button(frame, 3, 7, "Prev", () { calendarMonth = adjacentMonth(calendarMonth, -1); });
        at(frame, 10, 7, months[calendarMonth.month - 1] ~ " " ~ to!string(calendarMonth.year), 20,
            theme.foreground);
        button(frame, 31, 7, "Next", () { calendarMonth = adjacentMonth(calendarMonth, 1); });
        button(frame, 39, 7, "Back", &closeCalendar);

        auto today = todayISO();
        auto selectedDue = calendarDraft ? fields[2] : "";

        if (!calendarDraft)
        {
            if (auto task = find(calendarId))
                selectedDue = task.due;
        }

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
                auto cell = CellRect(3 + column * 6, 9 + row, 5, 1);
                auto label = "[" ~ (day < 10 ? " " : "") ~ to!string(day) ~ "]";
                at(frame, cell.x, cell.y, label, cell.width, iso == today ? theme.success : theme.foreground,
                    selectedDue == iso ? theme.selected : theme.panel);
                clickable(cell, chooseDay(iso));
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
            HelpRow("Due-date cells", "Open this task's calendar"),
            HelpRow("Priority cells", "Choose priority; Save applies"),
            HelpRow("Drag to date", "Schedule the task"),
            HelpRow("Wheel on tasks", "Move selection by one task"),
            HelpRow("Wheel elsewhere", "Scroll the current view"),
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

        auto position = to!string(helpOffset + 1) ~ "-"
            ~ to!string(min(helpLength, helpOffset + height)) ~ " / " ~ to!string(helpLength);
        line(frame, rows - 2, ink(theme.muted, fit("  " ~ position ~ " lines", columns)));
    }

    void scrollHelp(int amount, bool absolute = false)
    {
        helpOffset = max(0, min(max(0, helpLength - (rows - 9)),
            absolute ? amount : helpOffset + amount));
    }

    void closeHelp()
    {
        mode = Mode.browse;
    }

    /* One scroll step for the open view: help, the notes draft, or a description. */
    void scroll(int amount)
    {
        if (mode == Mode.help)
            scrollHelp(amount);
        else if (mode == Mode.descriptionEdit)
            scrollDraft(amount);
        else
            scrollDescription(amount);
    }

    void beginSearch()
    {
        if (mode == Mode.search)
            return;

        previousQuery = query;
        previousSearchId = currentId();
        searchCursor = to!dstring(query).length;
        mode = Mode.search;
    }

    void clearSearch()
    {
        query = "";
        searchCursor = 0;
        mode = Mode.browse;
        status = "Search cleared.";
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
        status = "Editing a draft. Save applies; Esc cancels.";
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
        status = calendarDraft ? "Pick a date for the draft; Save applies it." : "Click a day to schedule.";

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

    void pickDraftDate()
    {
        field = 2;
        beginCalendar();
    }

    void closeCalendar()
    {
        mode = calendarDraft ? Mode.edit : Mode.browse;
        status = "Calendar closed.";
    }

    void schedule(ulong id, string due)
    {
        if (auto task = find(id))
        {
            store.update(id, task.title, task.priority, due, task.notes);
            status = "Task #" ~ to!string(id) ~ ": " ~ (due.length ? due : "No date") ~ ".";
            refresh(id);
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
            const id = mode == Mode.calendar ? calendarId : currentId();
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

    /* Code-point offsets are always boundaries in the whole current field. */
    void editText(ref string text, ref size_t cursor, Event event, size_t limit)
    {
        auto points = to!dstring(text);
        auto boundaries = graphemeBoundaries(points);
        size_t boundary;

        while (boundaries[boundary] < cursor)
            ++boundary;

        bool changed;
        bool inserted;

        switch (event.key)
        {
            case Key.left:
                if (boundary > 0)
                    cursor = boundaries[boundary - 1];
                break;
            case Key.right:
                if (boundary + 1 < boundaries.length)
                    cursor = boundaries[boundary + 1];
                break;
            case Key.home: cursor = 0; break;
            case Key.end: cursor = points.length; break;
            case Key.backspace:
                if (cursor > 0)
                {
                    auto previous = boundaries[boundary - 1];
                    points = points[0 .. previous] ~ points[cursor .. $];
                    cursor = previous;
                    changed = true;
                }
                break;
            case Key.deleteKey:
                if (cursor < points.length)
                {
                    points = points[0 .. cursor] ~ points[boundaries[boundary + 1] .. $];
                    changed = true;
                }
                break;
            case Key.text:
                if (!event.pasted && event.text == "\x15")
                {
                    points = ""d;
                    cursor = 0;
                    changed = true;
                }
                else
                {
                    auto input = event.text;

                    if (event.pasted)
                    {
                        input = input.replace("\r\n", "\n").replace("\r", "\n");

                        if (mode != Mode.descriptionEdit)
                            input = input.replace("\n", " ").replace("\t", " ");
                    }

                    /* Reject the entire normalized event without moving the caret. */
                    if (text.length > limit || input.length > limit - text.length)
                        return;

                    const added = to!dstring(input);
                    points = points[0 .. cursor] ~ added ~ points[cursor .. $];
                    cursor += added.length;
                    changed = true;
                    inserted = true;
                }
                break;
            default: break;
        }

        if (changed)
        {
            /* Insertion/deletion can join either side or change RI pairing. */
            boundaries = graphemeBoundaries(points);
            size_t snapped;

            foreach (position; boundaries)
            {
                if (inserted || position <= cursor)
                    snapped = position;

                if (position >= cursor)
                    break;
            }

            cursor = snapped;
            text = to!string(points);
        }
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
                closeReader();
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
                cancelDelete();

            return;
        }

        if (mode == Mode.help)
        {
            if (event.key == Key.escape || (event.key == Key.text && (event.text == "?" || event.text == "q")))
                closeHelp();
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
                refresh(previousSearchId);
            }
            else if (event.key == Key.enter)
                mode = Mode.browse;
            else
            {
                const oldQuery = query;
                editText(query, searchCursor, event, 1024);

                if (query != oldQuery)
                    selected = 0;
            }

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
            case Key.escape: clearSearch(); return;
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

    void cancelDelete()
    {
        mode = Mode.browse;
        status = "Delete cancelled.";
    }

    void toggleTask(ulong id)
    {
        store.toggle(id);
        status = (find(id).completed ? "Completed" : "Reopened") ~ " task #" ~ to!string(id) ~ ".";
        refresh(id);
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
            case "/": beginSearch(); break;
            case "?": mode = Mode.help; helpOffset = 0; break;
            case " ":
                if (task !is null)
                    toggleTask(task.id);
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
                    status = "Deletion is permanent. Press y to confirm.";
                }
                break;
            case "r":
                theme = loadTheme(themePath);
                status = "Theme reloaded: " ~ theme.name ~ ".";
                break;
            case "m":
                motion.enabled = !motion.enabled;
                status = motion.enabled ? "Effects on. Editing stays still." : "Effects off for this session.";
                break;
            default: break;
        }
    }

    /*
     * Presses act on the controls of the frame the user is looking at, drawn
     * last first. The list itself is geometry: a press selects, opens a field,
     * or starts a drag that only a release over a date target commits.
     */
    void handleMouse(Event event)
    {
        const left = (event.button & 3) == 0 && event.button < 64;

        if (dragId != 0 && left && (event.motion || event.release))
        {
            continueDrag(event);
            return;
        }

        if (event.release || event.motion)
            return;

        if (event.button == 64 || event.button == 65)
        {
            if (dragId == 0)
                wheel(event.button == 64 ? -1 : 1, event.x, event.y);

            return;
        }

        if (!left)
            return;

        clearDrag();

        if (mode == Mode.search && event.y != 6)
            mode = Mode.browse;

        foreach_reverse (control; controls)
        {
            if (control.area.contains(event.x, event.y))
            {
                control.action();
                return;
            }
        }

        if (mode == Mode.descriptionEdit && descriptionBody(columns, rows).contains(event.x, event.y))
            placeDraftCaret(event.x, event.y);
        else if (browsing && event.y >= 8 && event.y < 8 + listHeight && event.x >= 3 && event.x <= listWidth)
            pressTask(event.x, event.y);
    }

    void continueDrag(Event event)
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

        auto id = dragId;
        const moved = dragging;
        const checkbox = pressX >= 3 && pressX <= 5 && event.x >= 3 && event.x <= 5 && event.y == pressY;
        auto target = scheduleHit(columns, rows, event.x, event.y);
        clearDrag();

        if (moved && target >= 0 && target < 5)
            schedule(id, normalizeDue(scheduleLabels[target], todayISO()));
        else if (moved)
            status = "Drop cancelled. No date changed.";
        else if (checkbox)
            toggleTask(id);
    }

    void wheel(int direction, int x, int y)
    {
        if (mode == Mode.reader || mode == Mode.help || mode == Mode.descriptionEdit
            || (browsing && previewBody().contains(x, y)))
            scroll(3 * direction);
        else if (browsing)
            selected += direction;
        else if (mode == Mode.calendar)
            calendarMonth = adjacentMonth(calendarMonth, direction);
    }

    /*
     * Select the pressed task. Its due-date and priority cells open their
     * controls; any other cell may become a drag, committed only on release.
     */
    void pressTask(int x, int y)
    {
        const index = offset + y - 8;

        if (index >= visible.length)
            return;

        selected = index;

        if (x >= listWidth - 12 && x < listWidth)
        {
            beginCalendar();
            return;
        }

        if (x >= listWidth - 21 && x < listWidth - 12)
        {
            beginEdit(true);
            field = 1;
            return;
        }

        dragId = store.tasks[visible[index]].id;
        pressX = x;
        pressY = y;
        dragging = false;
        dropTarget = -1;
    }

    /* Each factory call owns its argument; loop variables are never captured. */
    void delegate() showFilter(string value)
    {
        return () { filter = value; selected = 0; };
    }

    void delegate() focusField(int index)
    {
        return () {
            field = index;

            if (index == 3)
                beginDescriptionEdit();
        };
    }

    void delegate() choosePriority(string label)
    {
        return () {
            field = 1;
            fields[1] = label;
            cursors[1] = label.length;
        };
    }

    void delegate() chooseDay(string iso)
    {
        return () { chooseDate(iso); };
    }

    void delegate() scheduleAction(int index, bool calendar)
    {
        if (index == 5)
            return calendar ? &closeCalendar : &beginCalendar;

        return () { chooseDate(normalizeDue(scheduleLabels[index], todayISO())); };
    }

    void delegate() scrollAction(int amount)
    {
        return () { scroll(amount); };
    }
}

/* Fit text to width cells, ending clipped text with an ellipsis. */
private string elide(string text, int width)
{
    if (textWidth(text) <= width)
        return fit(text, width);

    return fit(stripRight(fit(text, width - 1)) ~ "\u2026", width);
}
