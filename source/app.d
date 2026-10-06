module app;

import dtask.model;
import dtask.theme;
import dtask.ui;
import std.conv : to;
import std.exception : enforce;
import std.file : exists;
import std.json : JSONValue;
import std.stdio : stderr, writeln;

/**
 * Dispatch CLI commands, or open the interactive workspace when no command is given.
 *
 * The interactive and scripting surfaces share the same validated store.
 * No terminal mode is entered until all command-line options, theme data,
 * and persisted tasks have been checked successfully.
 * Returns: 0 on success, or 1 after reporting an Exception to standard error.
 */
int main(string[] args)
{
    try
    {
        string dataPath;
        string themePath;
        string[] positional;
        string due;
        string notes;
        auto priority = Priority.normal;
        bool json;
        bool all;

        for (size_t index = 1; index < args.length; ++index)
        {
            auto argument = args[index];

            switch (argument)
            {
                case "--help":
                case "-h":
                    printHelp();
                    return 0;

                case "--version":
                    writeln("dtask 1.0.0");
                    return 0;

                case "--data":
                case "--theme":
                case "--priority":
                case "--due":
                case "--notes":
                    enforce(index + 1 < args.length, argument ~ " requires a value");
                    auto value = args[++index];

                    switch (argument)
                    {
                        case "--data":
                            enforce(value.length > 0, "--data requires a nonempty path");
                            dataPath = value;
                            break;

                        case "--theme": themePath = value; break;
                        case "--priority": priority = parsePriority(value); break;
                        case "--due": due = normalizeDue(value); break;
                        case "--notes": notes = value; break;
                        default: assert(0);
                    }
                    break;

                case "--json": json = true; break;
                case "--all": all = true; break;
                default:
                    enforce(argument.length == 0 || argument[0] != '-',
                        "Unknown option: " ~ argument);
                    positional ~= argument;
                    break;
            }
        }

        if (dataPath.length == 0)
            dataPath = defaultDataPath();

        if (themePath.length == 0)
        {
            const candidate = defaultThemePath();

            if (exists(candidate))
                themePath = candidate;
        }

        auto theme = loadTheme(themePath);
        auto store = new TaskStore(dataPath);
        scope (exit) store.close();

        if (positional.length == 0)
        {
            runUI(store, theme, themePath);
            return 0;
        }

        switch (positional[0])
        {
            case "add":
                enforce(positional.length == 2, "Usage: dtask add \"Title\" [--priority high] [--due tomorrow]");
                writeln("Added task #", store.add(positional[1], priority, due, notes));
                break;

            case "list":
                enforce(positional.length == 1, "Usage: dtask list [--all] [--json]");
                auto indices = sortedIndices(store.tasks, all ? "all" : "open", "");

                if (json)
                {
                    JSONValue[] rows;

                    foreach (index; indices)
                    {
                        auto task = store.tasks[index];
                        JSONValue row;
                        row["id"] = task.id;
                        row["title"] = task.title;
                        row["notes"] = task.notes;
                        row["priority"] = priorityLabel(task.priority);
                        row["due"] = task.due;
                        row["completed"] = task.completed;
                        row["created"] = task.created;
                        rows ~= row;
                    }

                    writeln(JSONValue(rows).toString());
                }
                else
                {
                    foreach (index; indices)
                    {
                        auto task = store.tasks[index];
                        writeln(task.completed ? "[x] #" : "[ ] #", task.id, "  ",
                            priorityLabel(task.priority), "  ",
                            task.due.length ? task.due : "no date", "  ", task.title);
                    }

                    if (indices.length == 0)
                    {
                        writeln("No tasks. Add one with: dtask add \"Your next step\"");
                    }
                }
                break;

            case "done":
            case "delete":
                enforce(positional.length == 2, "Usage: dtask " ~ positional[0] ~ " ID");
                auto id = to!ulong(positional[1]);

                if (positional[0] == "done")
                {
                    bool found;

                    foreach (task; store.tasks)
                    {
                        if (task.id == id)
                        {
                            found = true;

                            if (!task.completed)
                            {
                                store.toggle(id);
                            }

                            break;
                        }
                    }

                    enforce(found, "Task not found: " ~ positional[1]);
                    writeln("Completed task #", id);
                }
                else
                {
                    store.remove(id);
                    writeln("Deleted task #", id);
                }
                break;

            default:
                throw new Exception("Unknown command: " ~ positional[0] ~ ". Use --help.");
        }

        return 0;
    }
    catch (Exception error)
    {
        stderr.writeln("dtask: ", error.msg);
        return 1;
    }
}

private void printHelp()
{
    writeln(`dtask - a focused terminal task manager

Usage:
  dtask                              Open the interactive workspace
  dtask add "Title" [options]        Add a task
  dtask list [--all] [--json]        List open tasks, or all tasks
  dtask done ID                      Complete a task (idempotent)
  dtask delete ID                    Delete a task

Options:
  --data PATH       Use a separate JSON task store
  --theme PATH      Load a custom JSON theme
  --priority LEVEL  low, normal, high, urgent (default: normal)
  --due DATE        ISO date, tomorrow, fri, next week, weekend, +Nd
  --notes TEXT      Task notes
  --help, -h        Show this help
  --version         Show version

Keyboard:
  j/k or arrows: select     n: new        e/Enter: edit
  Space: complete/reopen    p: priority   d: delete (confirm)
  /: search                 1-4: views    ?: help
  v: full task reader       r: theme      m: effects
  Esc: cancel               q: quit

Mouse:
  Click a task to select it, or its checkbox to complete it.
  Click a due date for the calendar, or a priority to change it.
  Drag tasks to Today, Tomorrow, Weekend, Next week, or No date.
  Each wheel step over the list moves the selection by one task.
  Details opens the full description; the wheel scrolls it.
  Edit description opens a multiline draft; Save applies the edit.

Data: $XDG_DATA_HOME/dtask/tasks.json (default ~/.local/share/dtask/)
Theme: $XDG_CONFIG_HOME/dtask/theme.json (default ~/.config/dtask/)
Set DTASK_REDUCED_MOTION=1 to start with effects off.
Requires an ANSI/VT-compatible POSIX terminal; 24-bit color recommended.`);
}
