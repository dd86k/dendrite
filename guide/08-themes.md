# 8. Themes

Every look comes from a style struct with defaults in code, for its
variants too. A theme file overrides fields by name, per struct and per
variant. Set the file with
`WindowOptions.themePath`. Start from `examples/themes/dark.theme`, a
copy of the gallery's theme.

## The file

```ini
# Comments start with #.
[palette]
gray.900 = #17171a
blue.500 = #3b82f6
accent = blue.500
accent.hover = mix(accent, #ffffff, 15%)

[button]
fill = gray.800
radius = 4

[button.primary]
fill = accent
fillHover = accent.hover

[text.mono]
font = mono
size = 12.5
features = slashedZero | noContextual
```

- `[palette]` names colors. A token may name another token.
- A section per style struct, named by its `enum section`. Field names are
  the struct's.
- `[section.variant]` overrides fields for one variant. A variant starts
  from the base section, which starts from the struct defaults, then takes
  the variant's defaults in code, then this section.
- Colors are `#rrggbb`, `#rrggbbaa` or a palette token. `mix(a, b, N%)`
  moves `a` N% toward `b` and `fade(a, N%)` scales its alpha, as
  `Color.mix` and `Color.fade` do in code. They nest and take tokens.
  Other values are D literals: numbers, `true`, enum members such as
  `uiStrong`. Flags join members with `|`.
- `features` on `[text]`, `[textbox]` and `[textarea]` turns OpenType
  features on and off, such as `tabular`, `fractions` or `noLigatures`. The
  members are in `Features` in `dentrite.text`.

Ctrl+R reloads the theme file while the app runs, unless a focused node or
a shortcut takes the key. A theme with an error is not loaded, and the
error names the file and line.
`w.setTheme(new Theme(text, name))` applies a theme built in code, checked
the same way.

## Styles of your own

A style struct needs an `enum section`, and lists its variants in an enum
named `Variants`:

<!-- src="examples/source/guide/islands.d" from="struct ChartStyle" -->
```d
/// Look of the sensor chart, theme section `[chart]`.
struct ChartStyle
{
    enum section = "chart"; /// theme section

    /// Theme variants.
    enum Variants
    {
        alarm, /// a reading is past the limit
    }

    Color background = Color(0x17, 0x17, 0x1a, 0xff); /// behind the line
    Color line = Color(0x3b, 0x82, 0xf6, 0xff);       /// the readings
    float width = 1.5;                                /// line width
}
```

Read it while painting with `ctx.style!ChartStyle(variant)`, or in a node's
layout with `tree.style!ChartStyle(variant)`. Results are cached per
variant, and a reload clears them. The theme sections for it:

```ini
[chart]
background = gray.850
line = blue.500
width = 1.5

[chart.alarm]
line = red.400
width = 2.5
```

## Checking

A theme is checked when it loads: every section must belong to a style the
app reads, and every entry must be a field of the right type. The default
check knows the library's styles only (`LibraryStyles` in
`dentrite.host`), so an app with styles of its own passes the full list:

<!-- src="examples/source/guide/themes.d" from="alias GuideStyles" -->
```d
/// Styles the guide's theme may set: the library's, the chart's, and a button variant of the app.
alias GuideStyles = AliasSeq!(LibraryStyles, ChartStyle, Variants!(ButtonStyle, "large"));
```

```d
o.checkTheme = (Theme t) { t.check!GuideStyles(); };
```

`Variants!(ButtonStyle, "large")` adds a variant to a library style, so
`[button.large]` passes and `button("Big", variant: "large")` finds it.

Mistakes come back as messages naming the file and line:

<!-- src="examples/source/guide/themes.d" from="/// Mistakes name the file and line." -->
```d
/// Mistakes name the file and line.
unittest
{
    /// Message of checking theme `text`, or null when it passes.
    string error(string text)
    {
        try
        {
            new Theme(text, "app.theme").check!GuideStyles();
        }
        catch (Exception e)
        {
            return e.msg;
        }
        return null;
    }

    assert(error("[chart]\nwidht = 2\n") == "app.theme(2): ChartStyle has no field widht");
    assert(error("[chart.warning]\nwidth = 2\n") == "app.theme(1): no style reads section [chart.warning]");
    assert(error("[button.large]\npadX = 18\n") is null, "declared with Variants");
}
```

The same loader runs at compile time, so a theme read with `import()`
fails the build on a mistake:

<!-- src="examples/source/guide/themes.d" from="/// A theme read at compile time" -->
```d
/// A theme read at compile time fails the build on a mistake.
unittest
{
    enum string text = "[palette]\nred = #e5484d\n\n[chart]\nline = red\nwidth = 2\n";
    static assert(checkTheme!GuideStyles(text, "inline.theme"));
    enum ChartStyle c = loadStyle!ChartStyle(text, "inline.theme", null);
    static assert(c.width == 2 && c.line == Color(0xe5, 0x48, 0x4d, 0xff));
}
```
