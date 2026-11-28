/// OpenGL 3.3 core backend: draws a `FrameMesh` with one shader, the glyph atlas texture and a texture per image.
///
/// Every mesh a frame draws from, normally one per layer, keeps its own buffers until it is not drawn for
/// `keepFrames` frames, and is uploaded again only when its revision changes.
///
/// Blending is premultiplied, in the framebuffer's gamma space, as egui's GL backend does.
/// Custom draw batches get the GL context as is and the renderer restores its own state after.
module dentrite.backend.gl33;

import dentrite.c.gl;
import dentrite.draw;
import dentrite.geom;
import dentrite.image : Image;
import dentrite.platform : Renderer;
import dentrite.text : GlyphAtlas;
import std.exception : enforce;
import std.string : fromStringz;

/// Vertex shader: shifted physical pixels to clip space, texel coordinates to normalized.
private enum string vertexSource = `#version 330 core
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUV;
layout(location = 2) in vec4 aColor;
uniform vec2 uScreen;
uniform vec2 uOffset;
uniform sampler2D uAtlas;
out vec2 vUV;
out vec4 vColor;
void main()
{
    vUV = aUV / vec2(textureSize(uAtlas, 0));
    vColor = aColor;
    vec2 p = aPos + uOffset;
    gl_Position = vec4(p.x / uScreen.x * 2.0 - 1.0, 1.0 - p.y / uScreen.y * 2.0, 0.0, 1.0);
}
`;

/// Fragment shader: vertex color times the atlas or image texel, both premultiplied.
private enum string fragmentSource = `#version 330 core
in vec2 vUV;
in vec4 vColor;
uniform sampler2D uAtlas;
out vec4 outColor;
void main()
{
    outColor = vColor * texture(uAtlas, vUV);
}
`;

/// Compiles a shader of `kind` from `source`. Throws with the log on failure.
GLuint compileShader(GLenum kind, string source)
{
    GLuint s = glCreateShader(kind);
    const(char)* p = source.ptr;
    GLint len = cast(GLint) source.length;
    glShaderSource(s, 1, &p, &len);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (ok == GL_FALSE)
    {
        char[1024] log;
        GLsizei n;
        glGetShaderInfoLog(s, log.length, &n, log.ptr);
        throw new Exception("shader: " ~ log[0 .. n].idup);
    }
    return s;
}

/// Links a program from vertex and fragment sources. Throws with the log on failure.
GLuint linkProgram(string vs, string fs)
{
    GLuint v = compileShader(GL_VERTEX_SHADER, vs);
    GLuint f = compileShader(GL_FRAGMENT_SHADER, fs);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok == GL_FALSE)
    {
        char[1024] log;
        GLsizei n;
        glGetProgramInfoLog(p, log.length, &n, log.ptr);
        throw new Exception("link: " ~ log[0 .. n].idup);
    }
    return p;
}

/// Texture of an image and what it holds.
private struct ImageTexture
{
    GLuint id;     /// texture
    uint revision; /// image revision uploaded
    ulong used;    /// frame it was last drawn in
}

/// Buffers of a mesh and what they hold.
private struct MeshBuffers
{
    GLuint vao;    /// vertex layout over `vbo` and `ebo`
    GLuint vbo;    /// vertices
    GLuint ebo;    /// indices
    uint revision; /// mesh revision uploaded
    size_t bytes;  /// size of both buffers
    ulong used;    /// frame it was last drawn in
}

/// Frames an image or mesh keeps its GL objects after it was last drawn.
private enum ulong keepFrames = 120;

/// OpenGL 3.3 renderer. Keeps the glyph atlas and images as textures, and the buffers of recently drawn meshes.
final class GL33Renderer : Renderer
{
    size_t bufferBytes;      /// bytes held in mesh buffers
    /// Makes the renderer's GL context current, called before each render, `readPixels` and `dispose` when set.
    /// For windows each with a context of their own.
    void delegate() bind;

    private GLuint program;  /// UI shader
    private GLuint atlasTex; /// glyph atlas
    private GLint uScreen;   /// framebuffer size uniform
    private GLint uOffset;   /// vertex shift uniform
    private GLint uAtlas;    /// sampler uniform
    private int texW;        /// atlas texture width
    private int texH;        /// atlas texture height
    private GlyphAtlas synced; /// atlas the texture holds
    private ulong syncedTo;  /// first atlas frame whose changes the texture lacks
    private int frameW;      /// framebuffer width of the last frame
    private int frameH;      /// framebuffer height of the last frame
    private GLuint bound;    /// texture bound to unit 0
    private GLuint boundVao; /// vertex array bound, 0 for none
    private int offsetX;     /// `uOffset` x
    private int offsetY;     /// `uOffset` y
    private ImageTexture[Image] images; /// textures of images drawn lately
    private MeshBuffers[FrameMesh] meshes; /// buffers of meshes drawn lately
    private ulong frame;     /// frames rendered

    /// Creates GL objects. A context must be current and `loadGL` done.
    this()
    {
        program = linkProgram(vertexSource, fragmentSource);
        uScreen = glGetUniformLocation(program, "uScreen");
        uOffset = glGetUniformLocation(program, "uOffset");
        uAtlas = glGetUniformLocation(program, "uAtlas");
        glGenTextures(1, &atlasTex);
        glBindTexture(GL_TEXTURE_2D, atlasTex);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }

    /// Runs `bind` if set.
    private void bindContext()
    {
        if (bind !is null)
        {
            bind();
        }
    }

    /// Frees GL objects.
    void dispose()
    {
        bindContext();
        foreach (ref ImageTexture t; images)
        {
            glDeleteTextures(1, &t.id);
        }
        images = null;
        foreach (ref MeshBuffers b; meshes)
        {
            freeBuffers(b);
        }
        meshes = null;
        glDeleteTextures(1, &atlasTex);
        glDeleteProgram(program);
    }

    /// Driver description, for logs.
    string description()
    {
        return fromStringz(glGetString(GL_RENDERER)).idup ~ ", GL " ~ fromStringz(glGetString(GL_VERSION)).idup;
    }

    /// Uploads the atlas rows changed since the last upload, or all of it when new, resized or another atlas.
    private void upload(GlyphAtlas atlas)
    {
        glBindTexture(GL_TEXTURE_2D, atlasTex);
        glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        int top;
        int bottom;
        atlas.changedRows(syncedTo, top, bottom);
        // NOTE: every mesh of a frame is composed before any render, so no row changes after this in the frame
        syncedTo = atlas.frames + 1;
        if (texW != atlas.width || texH != atlas.height || atlas !is synced)
        {
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, atlas.width, atlas.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                atlas.pixels.ptr);
            texW = atlas.width;
            texH = atlas.height;
            synced = atlas;
            return;
        }
        if (bottom > top)
        {
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, top, atlas.width, bottom - top, GL_RGBA, GL_UNSIGNED_BYTE,
                atlas.pixels.ptr + top * atlas.width * 4);
        }
    }

    /// Sets the state the UI shader needs, after a custom draw or at frame start.
    private void bindState(int w, int h)
    {
        glViewport(0, 0, w, h);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_CULL_FACE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glEnable(GL_SCISSOR_TEST);
        glUseProgram(program);
        glUniform2f(uScreen, w, h);
        glUniform2f(uOffset, 0, 0);
        offsetX = 0;
        offsetY = 0;
        glUniform1i(uAtlas, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, atlasTex);
        bound = atlasTex;
        glBindVertexArray(0);
        boundVao = 0;
    }

    /// Clears to `clear` and draws `mesh`, uploading the meshes its batches draw from if new or changed.
    void render(FrameMesh mesh, GlyphAtlas atlas, Color clear)
    {
        bindContext();
        int w = mesh.width;
        int h = mesh.height;
        ++frame;
        frameW = w;
        frameH = h;
        upload(atlas);
        glDisable(GL_SCISSOR_TEST);
        glClearColor(clear.r / 255.0f, clear.g / 255.0f, clear.b / 255.0f, clear.a / 255.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        bindState(w, h);
        foreach (ref Batch b; mesh.batches)
        {
            glScissor(b.clip.x, h - b.clip.y - b.clip.h, b.clip.w, b.clip.h);
            if (b.callback !is null)
            {
                glBindVertexArray(0);
                b.callback(b.area, Rect(b.clip.x, b.clip.y, b.clip.w, b.clip.h), Size(w, h));
                bindState(w, h);
                continue;
            }
            GLuint tex = atlasTex;
            if (b.image !is null)
            {
                if (b.image.empty)
                {
                    continue;
                }
                tex = imageTexture(b.image);
            }
            if (tex != bound)
            {
                glBindTexture(GL_TEXTURE_2D, tex);
                bound = tex;
            }
            useMesh(b.source is null ? mesh : b.source);
            if (b.dx != offsetX || b.dy != offsetY)
            {
                glUniform2f(uOffset, b.dx, b.dy);
                offsetX = b.dx;
                offsetY = b.dy;
            }
            glDrawElements(GL_TRIANGLES, b.count, GL_UNSIGNED_INT, cast(void*)(b.start * uint.sizeof));
        }
        glBindVertexArray(0);
        boundVao = 0;
        glDisable(GL_SCISSOR_TEST);
        if (frame % keepFrames == 0)
        {
            dropStale();
        }
    }

    /// Binds the buffers of `m`, creating or uploading them if it is new or changed.
    private void useMesh(FrameMesh m)
    {
        MeshBuffers* t = m in meshes;
        bool fresh = t is null;
        if (fresh)
        {
            MeshBuffers n;
            glGenVertexArrays(1, &n.vao);
            glGenBuffers(1, &n.vbo);
            glGenBuffers(1, &n.ebo);
            glBindVertexArray(n.vao);
            glBindBuffer(GL_ARRAY_BUFFER, n.vbo);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, n.ebo);
            glEnableVertexAttribArray(0);
            glEnableVertexAttribArray(1);
            glEnableVertexAttribArray(2);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, Vertex.sizeof, cast(void*) Vertex.x.offsetof);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, Vertex.sizeof, cast(void*) Vertex.u.offsetof);
            glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, Vertex.sizeof, cast(void*) Vertex.rgba.offsetof);
            n.revision = m.revision - 1;
            meshes[m] = n;
            t = m in meshes;
            boundVao = n.vao;
        }
        if (t.vao != boundVao)
        {
            glBindVertexArray(t.vao);
            boundVao = t.vao;
        }
        t.used = frame;
        if (t.revision == m.revision)
        {
            return;
        }
        // NOTE: static at first, a mesh uploaded again is likely to change often
        GLenum usage = fresh ? GL_STATIC_DRAW : GL_DYNAMIC_DRAW;
        size_t vb = m.vertices.length * Vertex.sizeof;
        size_t ib = m.indices.length * uint.sizeof;
        glBindBuffer(GL_ARRAY_BUFFER, t.vbo);
        glBufferData(GL_ARRAY_BUFFER, vb, m.vertices.ptr, usage);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, ib, m.indices.ptr, usage);
        bufferBytes += vb + ib - t.bytes;
        t.bytes = vb + ib;
        t.revision = m.revision;
    }

    /// Deletes the GL objects of `b`.
    private void freeBuffers(ref MeshBuffers b)
    {
        glDeleteBuffers(1, &b.vbo);
        glDeleteBuffers(1, &b.ebo);
        glDeleteVertexArrays(1, &b.vao);
        bufferBytes -= b.bytes;
    }

    /// Texture of `img`, uploaded if new or changed.
    private GLuint imageTexture(Image img)
    {
        ImageTexture* t = img in images;
        if (t is null)
        {
            ImageTexture n;
            glGenTextures(1, &n.id);
            glBindTexture(GL_TEXTURE_2D, n.id);
            bound = n.id;
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, img.width, img.height, 0, GL_RGBA, GL_UNSIGNED_BYTE,
                img.pixels.ptr);
            n.revision = img.revision;
            images[img] = n;
            t = img in images;
        }
        else if (t.revision != img.revision)
        {
            glBindTexture(GL_TEXTURE_2D, t.id);
            bound = t.id;
            glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, img.width, img.height, GL_RGBA, GL_UNSIGNED_BYTE,
                img.pixels.ptr);
            t.revision = img.revision;
        }
        t.used = frame;
        return t.id;
    }

    /// Frees textures and buffers of images and meshes not drawn in the last `keepFrames` frames.
    private void dropStale()
    {
        Image[] stale;
        foreach (Image img, ref ImageTexture t; images)
        {
            if (frame - t.used > keepFrames)
            {
                glDeleteTextures(1, &t.id);
                stale ~= img;
            }
        }
        foreach (Image img; stale)
        {
            images.remove(img);
        }
        FrameMesh[] old;
        foreach (FrameMesh m, ref MeshBuffers b; meshes)
        {
            if (frame - b.used > keepFrames)
            {
                freeBuffers(b);
                old ~= m;
            }
        }
        foreach (FrameMesh m; old)
        {
            meshes.remove(m);
        }
    }

    /// Framebuffer contents of the last frame as RGBA8 rows, top row first. Call before the swap.
    ubyte[] readPixels()
    {
        bindContext();
        int w = frameW;
        int h = frameH;
        ubyte[] up = new ubyte[w * h * 4];
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, up.ptr);
        ubyte[] down = new ubyte[up.length];
        foreach (int y; 0 .. h)
        {
            down[y * w * 4 .. (y + 1) * w * 4] = up[(h - 1 - y) * w * 4 .. (h - y) * w * 4];
        }
        return down;
    }
}
