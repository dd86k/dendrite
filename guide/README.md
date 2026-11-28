# dentrite usage guide

How to build an application with dentrite. DDoc stays the API reference, and
`examples/gallery/` shows every widget in its variants. This guide is the
part in between: how the pieces fit, in the order you meet them.

1. [Getting started](01-start.md): dependency, fonts, the first window.
2. [Signals](02-signals.md): state, bindings, effects, owners.
3. [Layout](03-layout.md): rows, columns, sizes, panels, scrolling.
4. [Widgets](04-widgets.md): binding the common controls to signals.
5. [Collections](05-collections.md): keyed lists, virtual lists, tables, trees.
6. [Commands and menus](06-commands.md): shortcuts, menus, dialogs, tooltips.
7. [Islands](07-islands.md): immediate-mode code inside the retained tree.
8. [Themes](08-themes.md): theme files, style structs, variants.
9. [Threads](09-threads.md): handing work from other threads to the UI.
10. [Custom widgets](10-custom-widgets.md): a node of your own, and its island twin.
11. [Testing](11-testing.md): headless hosts, input, screenshots.
12. [Windows](12-windows.md): more top-level windows, sharing the app.

## Examples

Every code block comes from `examples/`, a dub package with a unittest
for each example. From `examples/`:

```sh
dub test                   # every example's tests, headless
dub run -- todo            # opens one example: counter, profile, shell, export,
                           # todo, log, table, editor, sensors, downloads,
                           # rating, windows
dub run -c hello           # the program of chapter 1
```

The examples load `../../fonts/` and `themes/dark.theme` relative to the
working directory, so run them from `examples/`.

## Keeping the guide in sync

A code block under a `<!-- src="..." from="..." -->` line is an excerpt of
the named file. After changing an example, from this directory:

```sh
perl tools/sync-snippets.pl *.md           # rewrite the excerpts
perl tools/sync-snippets.pl --check *.md   # exit 1 if any excerpt is stale
```
