/// Opens one of the guide's examples in a window: `dub run -- counter`.
module app;

import dentrite.containers;
import dentrite.host : Host;
import dentrite.immediate : Ui;
import dentrite.island : island;
import dentrite.node : Node;
import dentrite.signals;
import dentrite.theme : Theme;
import dentrite.window;
import guide.collections;
import guide.commands;
import guide.counter;
import guide.islands;
import guide.layout;
import guide.rating;
import guide.signals;
import guide.themes : GuideStyles;
import guide.threads;
import guide.widgets;
import guide.windows;
import std.algorithm.sorting : sort;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.stdio : stderr;

/// Builders of the runnable examples in window `h`, by name.
Node delegate()[string] examples(Host h)
{
    return [
        "counter": () => counter(),
        "profile": () => pad(all: 16)(profile()),
        "shell": () => shell(),
        "export": () => pad(all: 16)(exportForm(new ExportSettings)),
        "todo": () => pad(all: 16)(new Todo().view()),
        "log": () => logList(entries(100_000), signal(uint.max)),
        "table": () => logTable(entries(5000), signal(uint.max)),
        "editor": () => editor(h, new Notes),
        "sensors": () => sensors(),
        "downloads": () => downloads(h),
        "rating": () => ratings(),
        "windows": () => counterWithInspector(h, new Inspector),
    ];
}

/// Sensor island with a few readings.
Node sensors()
{
    Sensors s = new Sensors(["Inlet", "Outlet", "Pump"]);
    s.samples.set([0.2, 0.35, 0.3, 0.5, 0.45, 0.7, 0.6, 0.8, 0.75, 0.9]);
    return sensorView(s);
}

/// Downloads started at once.
Node downloads(Host h)
{
    static immutable string[] files = ["linux.iso", "photos.zip", "notes.tar"];
    Downloads d = new Downloads(files.dup);
    startDownloads(h, d, files);
    return downloadsView(d);
}

/// Retained and island ratings over the same value.
Node ratings()
{
    Signal!int stars = signal(3);
    return pad(all: 16)(column(gap: 12, cross: CrossAlign.start)(
        rating(stars, accessName: "Retained rating"),
        sized(w: 200, h: 24)(island((Ui ui) {
            int v = stars.get;
            if (ui.rating(v))
            {
                stars.set(v);
            }
        })),
    ));
}

/// Opens the example named by the first argument, counter by default, and runs until closed.
int main(string[] args)
{
    string shot;
    GetoptResult help = getopt(args, "shot", "Write a PNG of the first frames, then exit.", &shot);
    string name = args.length > 1 ? args[1] : "counter";
    if (help.helpWanted)
    {
        defaultGetoptPrinter("dentrite guide examples: dub run -- NAME", help.options);
        return 0;
    }
    WindowOptions o;
    o.title = "dentrite guide: " ~ name;
    o.width = 640;
    o.height = 480;
    o.fonts = ["../../fonts/Inter-Regular.otf", "../../fonts/Inter-SemiBold.otf",
        "../../fonts/JetBrainsMono-Regular.ttf"];
    o.themePath = "themes/dark.theme";
    o.checkTheme = (Theme t) { t.check!GuideStyles(); };
    scope Window w = new Window(o);
    Node delegate()[string] all = examples(w);
    Node delegate()* build = name in all;
    if (build is null)
    {
        stderr.writeln("unknown example ", name, ", expected one of: ", sort(all.keys));
        return 1;
    }
    scope Scope root = effectScope(() { w.setRoot((*build)()); });
    if (shot.length > 0)
    {
        import dentrite.script : settle;

        settle(w, 30);
        w.screenshotPath = shot;
        w.requestFrame();
        w.frame();
        return 0;
    }
    w.run();
    return 0;
}
