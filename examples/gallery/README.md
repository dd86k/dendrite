# gallery

Every dentrite widget in its variants and states, one page each: buttons,
check boxes, radio buttons, text, links, text boxes, text areas, spin boxes,
combo boxes, sliders, progress bars, tabs, menus, dialogs, tooltips, lists, a
chat feed, trees, tables, layout containers, the dock and islands. Each page
is short builder code in `source/gallery/pages.d`, meant to be read next to the
running page.

## Build and run

From this directory:

```sh
dub build
./bin/dentrite-gallery                 # loads ../../fonts/ and themes/ relative to the working directory
./bin/dentrite-gallery --page dock     # opens a page by name or file name
dub test                               # builds and lays out every page headless
```

Ctrl+R reloads `themes/dark.theme`, F12 writes a screenshot.

## Screenshots

```sh
xvfb-run -a ./bin/dentrite-gallery --shots shots/      # one PNG per page, such as shots/check-boxes.png
xvfb-run -a ./bin/dentrite-gallery --page menus --shot menu.png --script "click:237,294; wait:2"
```

`--shots` renders each page in a fresh state, so comparing a directory before
and after a change shows paint regressions: `magick compare -metric AE a.png
b.png null:`. Script steps are those of `dentrite.script`, see `--help`.
Coordinates are logical pixels, and the page content starts at x = 171.

## What's where

| Path | What |
|---|---|
| `source/app.d` | Options, window setup, `--shots` and `--shot`. |
| `source/gallery/shell.d` | Menu bar, page list and page switching, with a test building every page. |
| `source/gallery/pages.d` | The pages. |
| `themes/dark.theme` | The debugger's theme without its code view section, plus `[text.title]`. |
