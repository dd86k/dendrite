#!/usr/bin/env rdmd
/// Builds static FreeType, HarfBuzz and SDL3 libraries from source into `winlibs/`, where dub looks for them on
/// Windows, and for SDL3 also on Linux with the `dentrite:sdl3/static` configuration. Run
/// `rdmd tools/winlibs.d --freetype --harfbuzz --sdl3` from any shell, or `ldc2 -run tools/winlibs.d` with the same
/// options. `--help` lists them.
///
/// On Windows it compiles with cl, taken from PATH or else from the newest Visual Studio found by vswhere. The
/// static C runtime (/MT) matches LDC's default, `--md` switches to /MD for `-link-defaultlib-shared`. Elsewhere
/// it uses cc, c++ and ar, which for FreeType and HarfBuzz is only useful for checking the build. SDL3 builds
/// with CMake, and Ninja when found.
/// NOTE: FreeType gets the modules dentrite needs: TrueType and CFF outlines, the autohinter, the smooth
/// rasterizer, and zlib and libpng compiled into the same library for WOFF and PNG color emoji (CBDT). Type 1,
/// bitmap font formats, SDF and SVG are left out.
module winlibs;

import std.algorithm.searching : all, any, canFind, endsWith, startsWith;
import std.ascii : isDigit;
import std.array : join, replace, split;
import std.file : copy, exists, isDir, mkdirRecurse, read, readText, remove, rename, rmdirRecurse, write;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt, GetoptResult;
import std.path : absolutePath, buildNormalizedPath, buildPath, dirName, dirSeparator, pathSplitter;
import std.process : Config, environment, execute, spawnProcess, wait;
import std.stdio : stderr, stdout, writefln, writeln;
import std.string : indexOf, lineSplitter, strip;
import std.typecons : Tuple;
import std.uni : toLower, toUpper;
import std.zip : ArchiveMember, ZipArchive;

/// FreeType version downloaded by a bare `--freetype`.
enum freetypeDefault = "2.13.3";
/// zlib version FreeType is built with.
enum zlibVersion = "1.4";
/// libpng version FreeType is built with.
enum libpngVersion = "1.6.59";
/// HarfBuzz version downloaded by a bare `--harfbuzz`.
enum harfbuzzDefault = "15.2.0";
/// SDL3 version downloaded by a bare `--sdl3`.
enum sdl3Default = "3.4.20";
/// User agent for downloads.
enum userAgent = "dentrite-winlibs";

/// FreeType module classes kept from the source tree's module list.
immutable string[] freetypeModules = [
    "autofit_module_class", "tt_driver_class", "cff_driver_class", "psaux_module_class", "psnames_module_class",
    "pshinter_module_class", "sfnt_module_class", "ft_smooth_renderer_class",
];

/// FreeType sources for those modules, relative to the source tree.
immutable string[] freetypeSources = [
    "src/base/ftsystem.c", "src/base/ftinit.c", "src/base/ftdebug.c", "src/base/ftbase.c", "src/base/ftbbox.c",
    "src/base/ftbitmap.c", "src/base/ftglyph.c", "src/base/ftmm.c", "src/base/ftstroke.c", "src/base/ftsynth.c",
    "src/autofit/autofit.c", "src/cff/cff.c", "src/gzip/ftgzip.c", "src/psaux/psaux.c", "src/pshinter/pshinter.c",
    "src/psnames/psnames.c", "src/sfnt/sfnt.c", "src/smooth/smooth.c", "src/truetype/truetype.c",
];

/// zlib sources, the gz file functions left out.
immutable string[] zlibSources = [
    "adler32.c", "compress.c", "crc32.c", "deflate.c", "inffast.c", "inflate.c", "inftrees.c", "trees.c",
    "uncompr.c", "zutil.c",
];

/// libpng sources.
immutable string[] libpngSources = [
    "png.c", "pngerror.c", "pngget.c", "pngmem.c", "pngpread.c", "pngread.c", "pngrio.c", "pngrtran.c",
    "pngrutil.c", "pngset.c", "pngtrans.c", "pngwio.c", "pngwrite.c", "pngwtran.c", "pngwutil.c",
];

/// FreeType options for PNG glyphs and the zlib above, and libpng without the SIMD sources in its CPU directories.
/// NOTE: zlib symbols get a z_ prefix, as DMD's Phobos carries its own zlib in a single object file that would
/// clash. Z_PREFIX skips z_errmsg, renamed by hand.
immutable string[] freetypeDefines = [
    "FT2_BUILD_LIBRARY", "FT_CONFIG_OPTION_USE_PNG", "FT_CONFIG_OPTION_SYSTEM_ZLIB", "Z_PREFIX",
    "z_errmsg=z_z_errmsg", "PNG_ARM_NEON_OPT=0", "PNG_INTEL_SSE_OPT=0", "PNG_MIPS_MSA_OPT=0", "PNG_MIPS_MMI_OPT=0",
    "PNG_POWERPC_VSX_OPT=0", "PNG_LOONGARCH_LSX_OPT=0", "PNG_RISCV_RVV_OPT=0",
];

/// FreeType functions HarfBuzz looks for at configure time, all present since FreeType 2.11.
immutable string[] harfbuzzFreetypeDefines = [
    "HAVE_FREETYPE", "HAVE_FT_GET_VAR_BLEND_COORDINATES", "HAVE_FT_SET_VAR_BLEND_COORDINATES",
    "HAVE_FT_DONE_MM_VAR", "HAVE_FT_GET_TRANSFORM",
];

/// Compiler and archiver commands with the environment they run in.
struct Tools
{
    bool msvc;           /// cl and lib, else cc, c++ and ar
    bool sharedCrt;      /// /MD in place of /MT
    string cc;           /// C compiler
    string cxx;          /// C++ compiler
    string ar;           /// archiver
    string path;         /// PATH the tools see
    string[string] env;  /// whole environment for the tools, null to inherit
}

/// Prints the start of stage `what`.
void stage(string what)
{
    writeln("== ", what);
    stdout.flush();
}

/// Prints step `msg` of a stage.
void step(string msg)
{
    writeln("   ", msg);
    stdout.flush();
}

/// Source tree of library `label` for `what`: version `what` downloaded and unpacked into `srcDir` once, or else
/// directory `what`. `url` takes the version with dots replaced by `sep`. `marker` is a file every tree has.
/// `keep` lists the directories unpacked, all of them when null.
string sources(string label, string what, string srcDir, string url, string sep, string marker, string[] keep)
{
    string tree;
    if (what.all!(c => isDigit(c) || c == '.') == false)
    {
        if (exists(what) == false || isDir(what) == false)
        {
            throw new Exception(what ~ " is neither a version nor a directory");
        }
        tree = absolutePath(what);
        stage(label ~ ": sources in " ~ tree);
    }
    else
    {
        stage(label ~ " " ~ what ~ ": sources");
        string zip = buildPath(srcDir, label.toLower ~ "-" ~ what ~ ".zip");
        if (exists(zip))
        {
            step("downloaded before: " ~ zip);
        }
        else
        {
            string link = format(url, what.replace(".", sep));
            step("download " ~ link);
            run(Tools.init, ["curl", "-fL", "--retry", "2", "-A", userAgent, "-o", zip ~ ".part", link]);
            rename(zip ~ ".part", zip);
        }
        tree = unzip(zip, srcDir, keep);
    }
    if (exists(buildPath(tree, marker)) == false)
    {
        throw new Exception(format("%s has no %s, not a source tree", tree, marker));
    }
    return tree;
}

/// Unpacks the parts of `zip` under the `keep` directories of its top directory, or all of it when `keep` is
/// null, into `dir`, unless done before. Returns the unpacked top directory.
string unzip(string zip, string dir, string[] keep)
{
    ZipArchive archive = new ZipArchive(read(zip));
    string top;
    foreach (string name, ArchiveMember m; archive.directory)
    {
        top = name[0 .. name.indexOf('/') + 1];
        break;
    }
    if (top.length == 0)
    {
        throw new Exception(zip ~ " has no top directory");
    }
    string tree = buildPath(dir, top[0 .. $ - 1]);
    string done = tree ~ ".unpacked";
    if (exists(done))
    {
        step("unpacked before: " ~ tree);
        return tree;
    }
    step("unpack to " ~ tree);
    string base = buildNormalizedPath(absolutePath(dir)) ~ dirSeparator;
    size_t count;
    foreach (string name, ArchiveMember m; archive.directory)
    {
        string inner = name.startsWith(top) ? name[top.length .. $] : null;
        if (name.endsWith("/") || inner.length == 0
            || (keep !is null && keep.any!(k => inner.startsWith(k)) == false))
        {
            continue;
        }
        string path = buildNormalizedPath(absolutePath(dir), name);
        if (path.startsWith(base) == false)
        {
            throw new Exception("archive entry outside the directory: " ~ name);
        }
        mkdirRecurse(dirName(path));
        write(path, archive.expand(m));
        ++count;
    }
    write(done, "");
    step(format("%s files", count));
    return tree;
}

/// Compiles FreeType from `src`, with zlib from `zlibSrc` and libpng from `pngSrc`, into a static library in
/// `outDir`.
void buildFreetype(Tools tools, string src, string zlibSrc, string pngSrc, string outDir)
{
    stage("FreeType: module list");
    string inc = buildPath(outDir, "include");
    string list = readText(buildPath(src, "include/freetype/config/ftmodule.h"));
    string[] kept;
    foreach (string want; freetypeModules)
    {
        string found;
        foreach (string line; list.lineSplitter)
        {
            if (line.canFind("FT_USE_MODULE") && line.canFind(" " ~ want ~ " "))
            {
                found = line;
            }
        }
        if (found.length == 0)
        {
            throw new Exception("FreeType's module list has no " ~ want ~ ", update freetypeModules");
        }
        kept ~= found;
    }
    // Found before the source tree's own list, so ftinit.c registers only these modules
    string modules = buildPath(inc, "freetype/config/ftmodule.h");
    mkdirRecurse(dirName(modules));
    write(modules, "/* Modules dentrite needs, written by tools/winlibs.d */\n" ~ kept.join("\n") ~ "\n");
    step(format("%s modules: %-(%s, %)", kept.length, freetypeModules));
    copy(buildPath(pngSrc, "scripts/pnglibconf.h.prebuilt"), buildPath(inc, "pnglibconf.h"));
    string[] files;
    foreach (string f; freetypeSources)
    {
        files ~= buildPath(src, f);
    }
    foreach (string f; zlibSources)
    {
        files ~= buildPath(zlibSrc, f);
    }
    foreach (string f; libpngSources)
    {
        files ~= buildPath(pngSrc, f);
    }
    build(tools, "FreeType", "freetype", files, [inc, buildPath(src, "include"), zlibSrc, pngSrc],
        freetypeDefines.dup, false, outDir);
}

/// Compiles HarfBuzz from `src`, with FreeType functions from the headers in `ftSrc`, into a static library in
/// `outDir`.
void buildHarfbuzz(Tools tools, string src, string ftSrc, string outDir)
{
    build(tools, "HarfBuzz", "harfbuzz", [buildPath(src, "src/harfbuzz.cc")], [buildPath(ftSrc, "include")],
        harfbuzzFreetypeDefines.dup, true, outDir);
}

/// Compiles `files` as C or C++ with `includes` and `defines`, then archives them as library `name` in `outDir`.
/// `label` names the stages.
void build(Tools tools, string label, string name, string[] files, string[] includes, string[] defines, bool cpp,
    string outDir)
{
    stage(format("%s: compile %s file%s", label, files.length, files.length == 1 ? " (a big one, takes a while)"
        : "s"));
    string objDir = buildPath(outDir, "obj", name);
    mkdirRecurse(objDir);
    string[] objs;
    foreach (size_t n, string f; files)
    {
        string base = pathSplitter(f).back;
        string obj = buildPath(objDir, base[0 .. base.indexOf('.')] ~ (tools.msvc ? ".obj" : ".o"));
        string[] cmd;
        if (tools.msvc)
        {
            cmd = [cpp ? tools.cxx : tools.cc, "/nologo", "/c", "/O2", "/DNDEBUG", tools.sharedCrt ? "/MD" : "/MT",
                "/utf-8", "/D_CRT_SECURE_NO_WARNINGS", "/D_CRT_NONSTDC_NO_WARNINGS", "/Fo" ~ obj];
            if (cpp)
            {
                cmd ~= ["/std:c++17", "/bigobj", "/EHs-c-", "/GR-"];
            }
            foreach (string d; defines)
            {
                cmd ~= "/D" ~ d;
            }
            foreach (string i; includes)
            {
                cmd ~= "/I" ~ i;
            }
        }
        else
        {
            cmd = [cpp ? tools.cxx : tools.cc, "-c", "-O2", "-DNDEBUG", "-fPIC", "-o", obj];
            if (cpp)
            {
                cmd ~= ["-std=c++17", "-fno-exceptions", "-fno-rtti"];
            }
            foreach (string d; defines)
            {
                cmd ~= "-D" ~ d;
            }
            foreach (string i; includes)
            {
                cmd ~= "-I" ~ i;
            }
        }
        step(format("[%s/%s] %s", n + 1, files.length, base));
        // cl names each file it compiles, which the step line already did
        run(tools, cmd ~ f, false, tools.msvc);
        objs ~= obj;
    }
    string lib = buildPath(outDir, tools.msvc ? name ~ ".lib" : "lib" ~ name ~ ".a");
    stage(label ~ ": archive " ~ lib);
    if (exists(lib))
    {
        remove(lib);
    }
    run(tools, tools.msvc ? [tools.ar, "/nologo", "/OUT:" ~ lib] ~ objs : [tools.ar, "rcs", lib] ~ objs);
}

/// Builds SDL3 from `src` with CMake as a static library, on Windows also as SDL3.dll with its import library,
/// copies them into `outDir` and checks the libraries it links against those `dubFile` names.
void buildSdl(Tools tools, string src, string outDir, string dubFile)
{
    stage("SDL: configure");
    string cmake = toolPath(tools, "cmake");
    if (cmake.length == 0)
    {
        throw new Exception(tools.msvc ? "no cmake, install Visual Studio's C++ CMake tools" : "no cmake on PATH");
    }
    string ninja = toolPath(tools, "ninja");
    string dir = buildPath(outDir, "obj", "sdl3");
    string prefix = buildPath(dir, "install");
    // CMake's cache would keep settings from an earlier run
    if (exists(dir))
    {
        rmdirRecurse(dir);
    }
    string[] cmd = [cmake, "-S", src, "-B", dir];
    if (ninja.length > 0)
    {
        cmd ~= ["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" ~ ninja];
    }
    // The lib directory is pinned so a distribution's lib64 can't move the archive. Only Windows needs the DLL,
    // Linux has a system SDL3 for the dynamic configuration.
    cmd ~= ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" ~ prefix, "-DCMAKE_INSTALL_LIBDIR=lib",
        "-DSDL_SHARED=" ~ (tools.msvc ? "ON" : "OFF"), "-DSDL_STATIC=ON", "-DSDL_TESTS=OFF",
        "-DSDL_TEST_LIBRARY=OFF", "-DSDL_EXAMPLES=OFF"];
    if (tools.msvc)
    {
        // NOTE: cl can't write its precompiled header on a VM shared folder
        cmd ~= ["-DCMAKE_C_COMPILER=" ~ tools.cc, "-DCMAKE_CXX_COMPILER=" ~ tools.cxx,
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=" ~ (tools.sharedCrt ? "MultiThreadedDLL" : "MultiThreaded"),
            "-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON"];
    }
    else
    {
        cmd ~= "-DCMAKE_POSITION_INDEPENDENT_CODE=ON";
    }
    run(tools, cmd);
    stage("SDL: compile");
    run(tools, [cmake, "--build", dir, "--config", "Release"]);
    run(tools, [cmake, "--install", dir, "--config", "Release"], true);
    string[] files = tools.msvc ? ["lib/SDL3-static.lib", "lib/SDL3.lib", "bin/SDL3.dll"] : ["lib/libSDL3.a"];
    stage("SDL: copy into " ~ outDir);
    foreach (string f; files)
    {
        step(f);
        copy(buildPath(prefix, f), buildPath(outDir, pathSplitter(f).back));
    }
    checkDubLibs(readText(buildPath(prefix, "lib", "pkgconfig", "sdl3.pc")), dubFile);
}

/// Warns about libraries `pc`, the text of sdl3.pc, links that `dubFile` doesn't name, so a new SDL dependency
/// shows up here and not as a link error.
void checkDubLibs(string pc, string dubFile)
{
    stage("SDL: libraries against " ~ dubFile);
    version (Windows)
    {
        immutable string[] implicit;
    }
    else
    {
        immutable string[] implicit = ["c", "m", "dl", "pthread", "rt"]; // druntime links these
    }
    string dub = readText(dubFile);
    string[] seen;
    string[] missing;
    foreach (string line; pc.lineSplitter)
    {
        if (line.startsWith("Libs:", "Libs.private:") == 0)
        {
            continue;
        }
        foreach (string token; line.split)
        {
            string lib = token.startsWith("-l") ? token[2 .. $]
                : token.toLower.endsWith(".lib") ? token[0 .. $ - 4] : null;
            if (lib.length == 0 || lib.startsWith("SDL3") || implicit.canFind(lib) || seen.canFind(lib))
            {
                continue;
            }
            seen ~= lib;
            if (dub.canFind(`"` ~ lib ~ `"`) == false)
            {
                missing ~= lib;
            }
        }
    }
    if (missing.length > 0)
    {
        writefln("warning: the static configuration in %s lacks %-(%s %)", dubFile, missing);
    }
    else
    {
        step(seen.length == 0 ? "sdl3.pc lists nothing beyond what druntime links"
            : "names all the libraries sdl3.pc lists");
    }
}

/// Full path of program `name` on the PATH `tools` run with, or null.
string toolPath(Tools tools, string name)
{
    version (Windows)
    {
        name ~= ".exe";
    }
    return which(name, tools.path);
}

/// Compiler setup: cl from PATH or from Visual Studio's vcvars64.bat on Windows, gcc tools elsewhere.
/// `scratch` holds the batch file that reads the Visual Studio environment.
Tools findTools(bool sharedCrt, string scratch)
{
    stage("Compiler");
    Tools t;
    t.sharedCrt = sharedCrt;
    version (Windows)
    {
        t.msvc = true;
        t.cc = which("cl.exe", environment.get("PATH", ""));
        t.ar = which("lib.exe", environment.get("PATH", ""));
        if (t.cc.length > 0 && t.ar.length > 0)
        {
            t.path = environment.get("PATH", "");
            t.cxx = t.cc;
            step("on PATH: " ~ t.cc);
            return t;
        }
        string vswhere = buildPath(environment.get("ProgramFiles(x86)", `C:\Program Files (x86)`),
            `Microsoft Visual Studio\Installer\vswhere.exe`);
        if (exists(vswhere) == false)
        {
            throw new Exception("no cl on PATH and no vswhere, run from a Visual Studio x64 command prompt");
        }
        string vs = run(Tools.init, [vswhere, "-latest", "-products", "*", "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64", "-property", "installationPath"], true).strip;
        string vcvars = buildPath(vs, `VC\Auxiliary\Build\vcvars64.bat`);
        if (vs.length == 0 || exists(vcvars) == false)
        {
            throw new Exception("Visual Studio has no x64 C++ tools, install the C++ desktop workload");
        }
        step("Visual Studio: " ~ vs);
        step("load " ~ vcvars);
        mkdirRecurse(scratch);
        string bat = buildPath(scratch, "vcvars.bat");
        write(bat, "@call \"" ~ vcvars ~ "\" >nul\r\n@set\r\n");
        string path;
        foreach (string line; run(Tools.init, ["cmd", "/d", "/c", bat], true).lineSplitter)
        {
            ptrdiff_t eq = line.indexOf('=');
            if (eq > 0)
            {
                t.env[line[0 .. eq]] = line[eq + 1 .. $];
                if (line[0 .. eq].toUpper == "PATH")
                {
                    path = line[eq + 1 .. $];
                }
            }
        }
        t.path = path;
        // Windows finds a bare program name on this process's PATH, not the one given to the child
        t.cc = which("cl.exe", path);
        t.ar = which("lib.exe", path);
        if (t.cc.length == 0 || t.ar.length == 0)
        {
            throw new Exception("vcvars64.bat put no cl.exe or lib.exe on PATH");
        }
        t.cxx = t.cc;
        step("cl: " ~ t.cc);
    }
    else
    {
        t.cc = "cc";
        t.cxx = "c++";
        t.ar = "ar";
        t.path = environment.get("PATH", "");
        step("cc, c++ and ar");
    }
    return t;
}

/// Full path of `exe` in the directories of `path`, a PATH value, or null.
string which(string exe, string path)
{
    version (Windows)
    {
        enum char sep = ';';
    }
    else
    {
        enum char sep = ':';
    }
    foreach (string dir; path.split(sep))
    {
        if (dir.length > 0 && exists(buildPath(dir, exe)))
        {
            return buildPath(dir, exe);
        }
    }
    return null;
}

/// Runs `cmd` in `tools`' environment and throws on failure. With `capture` the output is returned, otherwise
/// it goes to the console, without its first line when `skipFirst`.
string run(Tools tools, string[] cmd, bool capture = false, bool skipFirst = false)
{
    Config cfg = tools.env is null ? Config.none : Config.newEnv;
    if (capture || skipFirst)
    {
        Tuple!(int, "status", string, "output") r = execute(cmd, tools.env, cfg);
        if (r.status != 0)
        {
            throw new Exception(format("%s failed:\n%s", cmd[0], r.output));
        }
        if (capture)
        {
            return r.output;
        }
        ptrdiff_t nl = r.output.indexOf('\n');
        string rest = nl < 0 ? null : r.output[nl + 1 .. $].strip;
        if (rest.length > 0)
        {
            writeln(rest);
        }
        return null;
    }
    if (wait(spawnProcess(cmd, tools.env, cfg)) != 0)
    {
        throw new Exception(cmd[0] ~ " failed");
    }
    return null;
}

/// Parses options, then fetches and builds what was asked.
int main(string[] args)
{
    string freetype;
    string harfbuzz;
    string sdl3;
    string root = dirName(dirName(absolutePath(__FILE_FULL_PATH__)));
    string outDir = buildPath(root, "winlibs");
    bool md;
    // getopt would take the next argument as the value of a bare flag
    foreach (ref string a; args[1 .. $])
    {
        switch (a)
        {
        case "--freetype":
            a ~= "=" ~ freetypeDefault;
            break;
        case "--harfbuzz":
            a ~= "=" ~ harfbuzzDefault;
            break;
        case "--sdl3":
            a ~= "=" ~ sdl3Default;
            break;
        default:
            break;
        }
    }
    GetoptResult opts;
    try
    {
        opts = getopt(args,
            "freetype", "Build FreeType: a version to download (" ~ freetypeDefault ~ " when bare) or a source "
                ~ "directory.", &freetype,
            "harfbuzz", "Build HarfBuzz: a version to download (" ~ harfbuzzDefault ~ " when bare) or a source "
                ~ "directory. Takes FreeType's headers from the FreeType sources.", &harfbuzz,
            "sdl3", "Build SDL3 with CMake: a version to download (" ~ sdl3Default ~ " when bare) or a source "
                ~ "directory.", &sdl3,
            "out", "Output directory, winlibs/ at the repository root by default.", &outDir,
            "md", "Link the C runtime as a DLL (/MD), for LDC's -link-defaultlib-shared.", &md);
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        return 1;
    }
    if (opts.helpWanted || args.length > 1 || (freetype.length == 0 && harfbuzz.length == 0 && sdl3.length == 0))
    {
        defaultGetoptPrinter("Builds static FreeType, HarfBuzz and SDL3 for dentrite.\n"
            ~ "Usage: rdmd tools/winlibs.d [--freetype[=VERSION|DIR]] [--harfbuzz[=VERSION|DIR]] "
            ~ "[--sdl3[=VERSION|DIR]]", opts.options);
        return opts.helpWanted ? 0 : 1;
    }
    try
    {
        Tools tools = findTools(md, outDir);
        string srcDir = buildPath(outDir, "src");
        mkdirRecurse(srcDir);
        if (freetype.length > 0 || harfbuzz.length > 0)
        {
            string ftSource = sources("FreeType", freetype.length > 0 ? freetype : freetypeDefault, srcDir,
                "https://github.com/freetype/freetype/archive/refs/tags/VER-%s.zip", "-", "src/base/ftinit.c",
                ["include/", "src/"]);
            if (freetype.length > 0)
            {
                string zlibSource = sources("zlib", zlibVersion, srcDir,
                    "https://github.com/madler/zlib/archive/refs/tags/v%s.zip", ".", "inflate.c", null);
                string pngSource = sources("libpng", libpngVersion, srcDir,
                    "https://github.com/pnggroup/libpng/archive/refs/tags/v%s.zip", ".",
                    "scripts/pnglibconf.h.prebuilt", null);
                buildFreetype(tools, ftSource, zlibSource, pngSource, outDir);
            }
            if (harfbuzz.length > 0)
            {
                string hbSource = sources("HarfBuzz", harfbuzz, srcDir,
                    "https://github.com/harfbuzz/harfbuzz/archive/refs/tags/%s.zip", ".", "src/harfbuzz.cc",
                    ["include/", "src/"]);
                buildHarfbuzz(tools, hbSource, ftSource, outDir);
            }
        }
        if (sdl3.length > 0)
        {
            string sdlSource = sources("SDL", sdl3, srcDir,
                "https://github.com/libsdl-org/SDL/archive/refs/tags/release-%s.zip", ".", "include/SDL3/SDL.h", null);
            buildSdl(tools, sdlSource, outDir, buildPath(root, "dub.sdl"));
        }
    }
    catch (Exception e)
    {
        stderr.writeln("winlibs: ", e.msg);
        return 1;
    }
    stage("Done, libraries in " ~ outDir);
    return 0;
}
