const std = @import("std");

// Asset generation step for devtool
pub const GenerateAssetsStep = struct {
    step: std.Build.Step,
    dist_path: []const u8,
    out_path: []const u8,

    pub fn init(b: *std.Build, dist_path: []const u8, out_path: []const u8) *GenerateAssetsStep {
        const self = b.allocator.create(GenerateAssetsStep) catch @panic("OOM");
        self.* = GenerateAssetsStep{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "generate assets",
                .owner = b,
                .makeFn = make,
            }),
            .dist_path = b.dupe(dist_path),
            .out_path = b.dupe(out_path),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *GenerateAssetsStep = @fieldParentPtr("step", step);
        const b = step.owner;

        var file = try std.fs.cwd().createFile(self.out_path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("// This file is auto-generated. Do not edit manually.\n");
        try writer.writeAll("const std = @import(\"std\");\n\n");
        try writer.writeAll("const Self = @This();\n\n");
        try writer.writeAll("path: []const u8,\n");
        try writer.writeAll("content: []const u8,\n");
        try writer.writeAll("mime_type: []const u8,\n");
        try writer.writeAll("response: [:0]const u8,\n\n");

        try writer.writeAll("pub fn init(\n");
        try writer.writeAll("    comptime path: []const u8,\n");
        try writer.writeAll("    comptime content: []const u8,\n");
        try writer.writeAll("    comptime mime_type: []const u8,\n");
        try writer.writeAll(") Self {\n");
        try writer.writeAll("    var buf: [20]u8 = undefined;\n");
        try writer.writeAll("    const n = std.fmt.bufPrint(&buf, \"{d}\", .{content.len}) catch unreachable;\n");
        try writer.writeAll("    const content_length = buf[0..n.len];\n");
        try writer.writeAll("    const response = \"HTTP/1.1 200 OK\\n\" ++\n");
        try writer.writeAll("        \"Content-Type: \" ++ mime_type ++ \"\\n\" ++\n");
        try writer.writeAll("        \"Content-Length: \" ++ content_length ++ \"\\n\" ++\n");
        try writer.writeAll("        \"\\n\" ++\n");
        try writer.writeAll("        content;\n");
        try writer.writeAll("    return Self{\n");
        try writer.writeAll("        .path = path,\n");
        try writer.writeAll("        .content = content,\n");
        try writer.writeAll("        .mime_type = mime_type,\n");
        try writer.writeAll("        .response = response,\n");
        try writer.writeAll("    };\n");
        try writer.writeAll("}\n\n");

        try writer.writeAll("pub const not_found_asset = Self.init(\n");
        try writer.writeAll("    \"/notfound.html\",\n");
        try writer.writeAll("    \"<div>Page not found</div>\",\n");
        try writer.writeAll("    \"text/html\",\n");
        try writer.writeAll(");\n\n");

        try writer.writeAll("pub const assets = [_]Self{\n");

        // Helper function to get MIME type from file extension
        const getMimeType = struct {
            fn get(path: []const u8) []const u8 {
                if (std.mem.endsWith(u8, path, ".html")) return "text/html";
                if (std.mem.endsWith(u8, path, ".css")) return "text/css";
                if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
                if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
                if (std.mem.endsWith(u8, path, ".png")) return "image/png";
                if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
                if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
                return "application/octet-stream";
            }
        }.get;

        // Recursively walk the dist directory and generate assets
        var dist_dir = try std.fs.cwd().openDir(self.dist_path, .{ .iterate = true });
        defer dist_dir.close();

        var walker = try dist_dir.walk(b.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            const web_path = try std.fmt.allocPrint(b.allocator, "/{s}", .{entry.path});
            const embed_path = try std.fmt.allocPrint(b.allocator, "dist/{s}", .{entry.path});
            const mime_type = getMimeType(entry.path);

            try writer.print("    Self.init(\n", .{});
            try writer.print("        \"{s}\",\n", .{web_path});
            try writer.print("        @embedFile(\"{s}\"),\n", .{embed_path});
            try writer.print("        \"{s}\",\n", .{mime_type});
            try writer.print("    ),\n", .{});
        }

        try writer.writeAll("};\n\n");

        try writer.writeAll("pub fn get_asset(path: []const u8) Self {\n");
        try writer.writeAll("    for (assets) |asset| {\n");
        try writer.writeAll("        if (std.mem.eql(u8, asset.path, path)) {\n");
        try writer.writeAll("            return asset;\n");
        try writer.writeAll("        }\n");
        try writer.writeAll("    }\n");
        try writer.writeAll("    return not_found_asset;\n");
        try writer.writeAll("}\n");
    }

    fn get_mime_type(filename: []const u8) []const u8 {
        if (std.mem.endsWith(u8, filename, ".html")) return "text/html";
        if (std.mem.endsWith(u8, filename, ".js")) return "application/javascript";
        if (std.mem.endsWith(u8, filename, ".css")) return "text/css";
        if (std.mem.endsWith(u8, filename, ".svg")) return "image/svg+xml";
        if (std.mem.endsWith(u8, filename, ".png")) return "image/png";
        if (std.mem.endsWith(u8, filename, ".jpg") or std.mem.endsWith(u8, filename, ".jpeg")) return "image/jpeg";
        if (std.mem.endsWith(u8, filename, ".gif")) return "image/gif";
        if (std.mem.endsWith(u8, filename, ".ico")) return "image/x-icon";
        if (std.mem.endsWith(u8, filename, ".woff")) return "font/woff";
        if (std.mem.endsWith(u8, filename, ".woff2")) return "font/woff2";
        if (std.mem.endsWith(u8, filename, ".ttf")) return "font/ttf";
        if (std.mem.endsWith(u8, filename, ".otf")) return "font/otf";
        if (std.mem.endsWith(u8, filename, ".json")) return "application/json";
        if (std.mem.endsWith(u8, filename, ".xml")) return "application/xml";
        if (std.mem.endsWith(u8, filename, ".pdf")) return "application/pdf";
        if (std.mem.endsWith(u8, filename, ".txt")) return "text/plain";
        return "application/octet-stream";
    }
};
