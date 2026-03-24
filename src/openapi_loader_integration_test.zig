const std = @import("std");
const testing = std.testing;
const loader = @import("openapi/loader.zig");

fn writeSpec(tmp: *testing.TmpDir, allocator: std.mem.Allocator, name: []const u8, data: []const u8) ![]u8 {
    try tmp.dir.writeFile(.{ .sub_path = name, .data = data });
    return try tmp.dir.realpathAlloc(allocator, name);
}

test "load operations from JSON OpenAPI" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/health": {
        \\      "get": {
        \\        "summary": "Health",
        \\        "responses": {
        \\          "200": { "description": "ok" }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "spec.json", spec);
    defer testing.allocator.free(path);

    var ops = try loader.loadOperationsFromFile(testing.allocator, path);
    defer ops.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ops.items.len);
    try testing.expectEqualStrings("get:/health", ops.items[0].id);
    try testing.expectEqualStrings("Health", ops.items[0].summary.?);
}

test "describe resolves refs and composed schemas" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/complex": {
        \\      "post": {
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": { "$ref": "#/components/schemas/Composed" }
        \\            }
        \\          }
        \\        },
        \\        "responses": {
        \\          "200": {
        \\            "description": "ok",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": { "$ref": "#/components/schemas/Result" }
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "Result": {
        \\        "type": "object",
        \\        "properties": { "id": { "type": "string" } },
        \\        "required": ["id"]
        \\      },
        \\      "A": {
        \\        "type": "object",
        \\        "properties": { "a": { "type": "string" } }
        \\      },
        \\      "B": {
        \\        "type": "object",
        \\        "properties": { "b": { "type": "string" } }
        \\      },
        \\      "Composed": {
        \\        "allOf": [
        \\          { "$ref": "#/components/schemas/A" },
        \\          { "$ref": "#/components/schemas/B" }
        \\        ],
        \\        "additionalProperties": { "$ref": "#/components/schemas/Result" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "spec.json", spec);
    defer testing.allocator.free(path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, path, "post:/complex")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.request_body_required);
    try testing.expect(details.request_body_schemas.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.request_body_schemas[0], "allOf") != null);
    try testing.expect(std.mem.indexOf(u8, details.request_body_schemas[0], "additionalProperties") != null);

    try testing.expect(details.responses.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.responses[0], "$ref:Result") != null);
}

test "load YAML OpenAPI via native parser" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\openapi: 3.0.3
        \\paths:
        \\  /ping:
        \\    get:
        \\      summary: ping
        \\      responses:
        \\        '200':
        \\          description: ok
    ;

    const path = try writeSpec(&tmp, testing.allocator, "spec.yaml", spec);
    defer testing.allocator.free(path);

    var ops = try loader.loadOperationsFromFile(testing.allocator, path);
    defer ops.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), ops.items.len);
    try testing.expectEqualStrings("get:/ping", ops.items[0].id);
}

test "resolve external file refs for params and responses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const external =
        \\openapi: 3.0.3
        \\components:
        \\  parameters:
        \\    LimitParam:
        \\      name: limit
        \\      in: query
        \\      required: false
        \\      schema:
        \\        type: integer
        \\  responses:
        \\    OkResp:
        \\      description: ok from external
        \\      content:
        \\        application/json:
        \\          schema:
        \\            type: object
        \\            properties:
        \\              status:
        \\                type: string
    ;
    const common_path = try writeSpec(&tmp, testing.allocator, "common.yaml", external);
    defer testing.allocator.free(common_path);

    const root =
        \\openapi: 3.0.3
        \\paths:
        \\  /x:
        \\    get:
        \\      parameters:
        \\        - $ref: './common.yaml#/components/parameters/LimitParam'
        \\      responses:
        \\        '200':
        \\          $ref: './common.yaml#/components/responses/OkResp'
    ;
    const root_path = try writeSpec(&tmp, testing.allocator, "root.yaml", root);
    defer testing.allocator.free(root_path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, root_path, "get:/x")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.parameters.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.parameters[0], "limit [query] optional") != null);
    try testing.expect(details.responses.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.responses[0], "ok from external") != null);
}

test "json pointer escaped tokens ~1 and ~0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/y": {
        \\      "get": {
        \\        "responses": {
        \\          "200": {
        \\            "description": "ok",
        \\            "content": {
        \\              "application/json": {
        \\                "schema": { "$ref": "#/components/schemas/a~1b" }
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "a/b": {
        \\        "type": "object",
        \\        "properties": {
        \\          "x~y": { "type": "string" }
        \\        },
        \\        "required": ["x~y"]
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "escaped.json", spec);
    defer testing.allocator.free(path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, path, "get:/y")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.responses.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.responses[0], "$ref:a~1b") != null);
    try testing.expect(std.mem.indexOf(u8, details.responses[0], "props:1") != null);
}

test "describe returns null for missing operation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/only": { "get": { "responses": { "200": { "description": "ok" } } } }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "missing.json", spec);
    defer testing.allocator.free(path);

    const maybe = try loader.loadOperationDetailsFromFile(testing.allocator, path, "post:/only");
    try testing.expect(maybe == null);
}

test "describe includes oneOf and anyOf schema summaries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/union": {
        \\      "post": {
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "oneOf": [
        \\                  { "$ref": "#/components/schemas/A" },
        \\                  { "$ref": "#/components/schemas/B" }
        \\                ],
        \\                "anyOf": [
        \\                  { "type": "string" },
        \\                  { "type": "number" }
        \\                ]
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": { "200": { "description": "ok" } }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "schemas": {
        \\      "A": { "type": "object", "properties": { "a": { "type": "string" } } },
        \\      "B": { "type": "object", "properties": { "b": { "type": "string" } } }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "union.json", spec);
    defer testing.allocator.free(path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, path, "post:/union")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.request_body_schemas.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.request_body_schemas[0], "oneOf") != null);
    try testing.expect(std.mem.indexOf(u8, details.request_body_schemas[0], "anyOf") != null);
}

test "describe resolves chained local refs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/chain": {
        \\      "get": {
        \\        "responses": {
        \\          "200": { "$ref": "#/components/responses/RespA" }
        \\        }
        \\      }
        \\    }
        \\  },
        \\  "components": {
        \\    "responses": {
        \\      "RespA": { "$ref": "#/components/responses/RespB" },
        \\      "RespB": {
        \\        "description": "resolved chain",
        \\        "content": {
        \\          "application/json": {
        \\            "schema": { "type": "object", "properties": { "ok": { "type": "boolean" } } }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "chain.json", spec);
    defer testing.allocator.free(path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, path, "get:/chain")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.responses.len == 1);
    try testing.expect(std.mem.indexOf(u8, details.responses[0], "resolved chain") != null);
}

test "operations include multiple methods for same path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/items": {
        \\      "get": { "responses": { "200": { "description": "ok" } } },
        \\      "post": { "responses": { "201": { "description": "created" } } }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "multi.json", spec);
    defer testing.allocator.free(path);

    var ops = try loader.loadOperationsFromFile(testing.allocator, path);
    defer ops.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), ops.items.len);
    var found_get = false;
    var found_post = false;
    for (ops.items) |op| {
        if (std.mem.eql(u8, op.id, "get:/items")) found_get = true;
        if (std.mem.eql(u8, op.id, "post:/items")) found_post = true;
    }
    try testing.expect(found_get);
    try testing.expect(found_post);
}

test "describe extracts request body field lines" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\{
        \\  "openapi": "3.0.3",
        \\  "paths": {
        \\    "/auth/login": {
        \\      "post": {
        \\        "requestBody": {
        \\          "required": true,
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "type": "object",
        \\                "properties": {
        \\                  "email": { "type": "string" },
        \\                  "password": { "type": "string" }
        \\                },
        \\                "required": ["email", "password"]
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": { "200": { "description": "ok" } }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const path = try writeSpec(&tmp, testing.allocator, "fields.json", spec);
    defer testing.allocator.free(path);

    var details = (try loader.loadOperationDetailsFromFile(testing.allocator, path, "post:/auth/login")) orelse return error.TestExpectedEqual;
    defer details.deinit(testing.allocator);

    try testing.expect(details.request_body_fields.len == 2);
    try testing.expect(std.mem.indexOf(u8, details.request_body_fields[0], "email: string (required)") != null or std.mem.indexOf(u8, details.request_body_fields[1], "email: string (required)") != null);
    try testing.expect(std.mem.indexOf(u8, details.request_body_fields[0], "password: string (required)") != null or std.mem.indexOf(u8, details.request_body_fields[1], "password: string (required)") != null);
}

test "loads default server url from OpenAPI servers array" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const spec =
        \\openapi: 3.0.3
        \\servers:
        \\  - url: http://localhost:3333
        \\paths:
        \\  /health:
        \\    get:
        \\      responses:
        \\        '200':
        \\          description: ok
    ;

    const path = try writeSpec(&tmp, testing.allocator, "servers.yaml", spec);
    defer testing.allocator.free(path);

    const maybe_server = try loader.loadDefaultServerUrlFromFile(testing.allocator, path);
    defer if (maybe_server) |server| testing.allocator.free(server);

    try testing.expect(maybe_server != null);
    try testing.expectEqualStrings("http://localhost:3333", maybe_server.?);
}
