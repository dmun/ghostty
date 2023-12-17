const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const gl = @import("opengl");

/// Represents a single image placement on the grid. A placement is a
/// request to render an instance of an image.
pub const Placement = struct {
    /// The image being rendered. This MUST be in the image map.
    image_id: u32,

    /// The grid x/y where this placement is located.
    x: u32,
    y: u32,
    z: i32,

    /// The width/height of the placed image.
    width: u32,
    height: u32,

    /// The offset in pixels from the top left of the cell. This is
    /// clamped to the size of a cell.
    cell_offset_x: u32,
    cell_offset_y: u32,

    /// The source rectangle of the placement.
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

/// The map used for storing images.
pub const ImageMap = std.AutoHashMapUnmanaged(u32, struct {
    image: Image,
    transmit_time: std.time.Instant,
});

/// The state for a single image that is to be rendered. The image can be
/// pending upload or ready to use with a texture.
pub const Image = union(enum) {
    /// The image is pending upload to the GPU. The different keys are
    /// different formats since some formats aren't accepted by the GPU
    /// and require conversion.
    ///
    /// This data is owned by this union so it must be freed once the
    /// image is uploaded.
    pending_rgb: Pending,
    pending_rgba: Pending,

    /// This is the same as the pending states but there is a texture
    /// already allocated that we want to replace.
    replace_rgb: Replace,
    replace_rgba: Replace,

    /// The image is uploaded and ready to be used.
    ready: gl.Texture,

    /// The image is uploaded but is scheduled to be unloaded.
    unload_pending: []u8,
    unload_ready: gl.Texture,
    unload_replace: struct { []u8, gl.Texture },

    pub const Replace = struct {
        texture: gl.Texture,
        pending: Pending,
    };

    /// Pending image data that needs to be uploaded to the GPU.
    pub const Pending = struct {
        height: u32,
        width: u32,

        /// Data is always expected to be (width * height * depth). Depth
        /// is based on the union key.
        data: [*]u8,

        pub fn dataSlice(self: Pending, d: u32) []u8 {
            return self.data[0..self.len(d)];
        }

        pub fn len(self: Pending, d: u32) u32 {
            return self.width * self.height * d;
        }
    };

    pub fn deinit(self: Image, alloc: Allocator) void {
        switch (self) {
            .pending_rgb => |p| alloc.free(p.dataSlice(3)),
            .pending_rgba => |p| alloc.free(p.dataSlice(4)),
            .unload_pending => |data| alloc.free(data),

            .replace_rgb => |r| {
                alloc.free(r.pending.dataSlice(3));
                r.texture.destroy();
            },

            .replace_rgba => |r| {
                alloc.free(r.pending.dataSlice(4));
                r.texture.destroy();
            },

            .unload_replace => |r| {
                alloc.free(r[0]);
                r[1].destroy();
            },

            .ready,
            .unload_ready,
            => |tex| tex.destroy(),
        }
    }

    /// Mark this image for unload whatever state it is in.
    pub fn markForUnload(self: *Image) void {
        self.* = switch (self.*) {
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => return,

            .ready => |obj| .{ .unload_ready = obj },
            .pending_rgb => |p| .{ .unload_pending = p.dataSlice(3) },
            .pending_rgba => |p| .{ .unload_pending = p.dataSlice(4) },
            .replace_rgb => |r| .{ .unload_replace = .{
                r.pending.dataSlice(3), r.texture,
            } },
            .replace_rgba => |r| .{ .unload_replace = .{
                r.pending.dataSlice(4), r.texture,
            } },
        };
    }

    /// Replace the currently pending image with a new one. This will
    /// attempt to update the existing texture if it is already allocated.
    /// If the texture is not allocated, this will act like a new upload.
    ///
    /// This function only marks the image for replace. The actual logic
    /// to replace is done later.
    pub fn markForReplace(self: *Image, alloc: Allocator, img: Image) !void {
        assert(img.pending() != null);

        // Get our existing texture. This switch statement will also handle
        // scenarios where there is no existing texture and we can modify
        // the self pointer directly.
        const existing: gl.Texture = switch (self.*) {
            // For pending, we can free the old data and become pending ourselves.
            .pending_rgb => |p| {
                alloc.free(p.dataSlice(3));
                self.* = img;
                return;
            },

            .pending_rgba => |p| {
                alloc.free(p.dataSlice(4));
                self.* = img;
                return;
            },

            // If we're marked for unload but we just have pending data,
            // this behaves the same as a normal "pending": free the data,
            // become new pending.
            .unload_pending => |data| {
                alloc.free(data);
                self.* = img;
                return;
            },

            .unload_replace => |r| existing: {
                alloc.free(r[0]);
                break :existing r[1];
            },

            // If we were already pending a replacement, then we free our
            // existing pending data and use the same texture.
            .replace_rgb => |r| existing: {
                alloc.free(r.pending.dataSlice(3));
                break :existing r.texture;
            },

            .replace_rgba => |r| existing: {
                alloc.free(r.pending.dataSlice(4));
                break :existing r.texture;
            },

            // For both ready and unload_ready, we need to replace the
            // texture. We can't do that here, so we just mark ourselves
            // for replacement.
            .ready, .unload_ready => |tex| tex,
        };

        // We now have an existing texture, so set the proper replace key.
        self.* = switch (img) {
            .pending_rgb => |p| .{ .replace_rgb = .{
                .texture = existing,
                .pending = p,
            } },

            .pending_rgba => |p| .{ .replace_rgba = .{
                .texture = existing,
                .pending = p,
            } },

            else => unreachable,
        };
    }

    /// Returns true if this image is pending upload.
    pub fn isPending(self: Image) bool {
        return self.pending() != null;
    }

    /// Returns true if this image is pending an unload.
    pub fn isUnloading(self: Image) bool {
        return switch (self) {
            .unload_pending,
            .unload_ready,
            => true,

            .ready,
            .pending_rgb,
            .pending_rgba,
            => false,
        };
    }

    /// Converts the image data to a format that can be uploaded to the GPU.
    /// If the data is already in a format that can be uploaded, this is a
    /// no-op.
    pub fn convert(self: *Image, alloc: Allocator) !void {
        switch (self.*) {
            .ready,
            .unload_pending,
            .unload_replace,
            .unload_ready,
            => unreachable, // invalid

            .pending_rgba,
            .replace_rgba,
            => {}, // ready

            // RGB needs to be converted to RGBA because Metal textures
            // don't support RGB.
            .pending_rgb => |*p| {
                // Note: this is the slowest possible way to do this...
                const data = p.dataSlice(3);
                const rgba = try rgbToRgba(alloc, data);
                alloc.free(data);
                p.data = rgba.ptr;
                self.* = .{ .pending_rgba = p.* };
            },

            .replace_rgb => |*r| {
                const data = r.pending.dataSlice(3);
                const rgba = try rgbToRgba(alloc, data);
                alloc.free(data);
                r.pending.data = rgba.ptr;
                self.* = .{ .replace_rgba = r.* };
            },
        }
    }

    fn rgbToRgba(alloc: Allocator, data: []const u8) ![]u8 {
        const pixels = data.len / 3;
        var rgba = try alloc.alloc(u8, pixels * 4);
        errdefer alloc.free(rgba);
        var i: usize = 0;
        while (i < pixels) : (i += 1) {
            const data_i = i * 3;
            const rgba_i = i * 4;
            rgba[rgba_i] = data[data_i];
            rgba[rgba_i + 1] = data[data_i + 1];
            rgba[rgba_i + 2] = data[data_i + 2];
            rgba[rgba_i + 3] = 255;
        }

        return rgba;
    }

    /// Upload the pending image to the GPU and change the state of this
    /// image to ready.
    pub fn upload(
        self: *Image,
        alloc: Allocator,
    ) !void {
        // Convert our data if we have to
        try self.convert(alloc);

        // Get our pending info
        const p = self.pending().?;

        // Get our format
        const formats: struct {
            internal: gl.Texture.InternalFormat,
            format: gl.Texture.Format,
        } = switch (self.*) {
            .pending_rgb, .replace_rgb => .{ .internal = .rgb, .format = .rgb },
            .pending_rgba, .replace_rgba => .{ .internal = .rgba, .format = .rgba },
            else => unreachable,
        };

        // Create our texture
        const tex = try gl.Texture.create();
        errdefer tex.destroy();

        const texbind = try tex.bind(.@"2D");
        try texbind.parameter(.WrapS, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.WrapT, gl.c.GL_CLAMP_TO_EDGE);
        try texbind.parameter(.MinFilter, gl.c.GL_LINEAR);
        try texbind.parameter(.MagFilter, gl.c.GL_LINEAR);
        try texbind.image2D(
            0,
            formats.internal,
            @intCast(p.width),
            @intCast(p.height),
            0,
            formats.format,
            .UnsignedByte,
            p.data,
        );

        // Uploaded. We can now clear our data and change our state.
        self.deinit(alloc);
        self.* = .{ .ready = tex };
    }

    /// Our pixel depth
    fn depth(self: Image) u32 {
        return switch (self) {
            .pending_rgb => 3,
            .pending_rgba => 4,
            .replace_rgb => 3,
            .replace_rgba => 4,
            else => unreachable,
        };
    }

    /// Returns true if this image is in a pending state and requires upload.
    fn pending(self: Image) ?Pending {
        return switch (self) {
            .pending_rgb,
            .pending_rgba,
            => |p| p,

            .replace_rgb,
            .replace_rgba,
            => |r| r.pending,

            else => null,
        };
    }
};