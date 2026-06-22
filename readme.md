# zflecs

Idiomatic Zig 0.16 bindings for the [flecs](https://github.com/SanderMertens/flecs)
entity-component-system (flecs **v4.1.1**, fetched via `build.zig.zon`).

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

fn move(dt: flecs.Delta, pos: *Position, vel: *const Velocity) void {
    pos.x += vel.x * dt.s;
    pos.y += vel.y * dt.s;
}

var world = try flecs.World(.{}).init(.{});
defer world.deinit();

_ = world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .x = 1, .y = 2 } });
_ = world.system(.on_update, move);
while (world.progress(1.0 / 60.0)) {}
```

## Design

One rule: **the binding translates *declarations* into flecs calls; it never
invents runtime behavior.** Everything is a plain Zig container, and everything
comptime can derive is derived:

- **Components** are plain structs; tags are zero-size structs.
- **A system is a function** whose *signature is its query*.
- **A query is a struct** whose *fields are its terms* (named rows).
- **Configuration is a declaration** on the type - `pub const flecs_traits`,
  `pub const sort`, `pub fn onAdd`, … - never a parallel descriptor bag.
- **Modules and extensions are Zig containers.**

Pointer-ness encodes access (`*T` read-write, `*const T` read, `?*const T`
optional); wrapper types encode operators (`With`, `Up`, `Pair`, …).

## Build

```sh
zig build test          # run the test suite (the executable spec)
zig build examples      # build every example
zig build run-hello     # run one example
```

### Use as a dependency

Fetch it into your project (records the URL + hash in `build.zig.zon`):

```sh
zig fetch --save git+https://github.com/zigsel/flecs
```

Then wire the `flecs` module into your `build.zig`:

```zig
const zflecs = b.dependency("zflecs", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("flecs", zflecs.module("flecs"));
```

That's all — the dependency pulls the flecs amalgamation from its own upstream
release, compiles it, and links libc for you. In code: `const flecs =
@import("flecs");`.

> Building this package itself extracts the flecs source into a project-local
> `zig-pkg/` (a build cache artifact — gitignored, regenerated on demand).

## Tour

### Components

```zig
const Position = struct { x: f32, y: f32 };          // plain data
const Active = struct {};                            // zero-size -> tag

const Gravity = struct {                             // singleton
    g: f32 = 9.81,
    pub const flecs_traits: flecs.Traits = .{ .singleton = true };
};

const Mesh = struct {                                // lifecycle hooks as decls
    handle: Handle,
    pub fn onAdd(self: *Mesh) void { self.handle = acquire(); }
    pub fn onRemove(self: *Mesh) void { self.handle.release(); }
    pub fn deinit(self: *Mesh) void { self.handle.release(); }   // dtor hook
};
```

Configure traits on the type, or explicitly - every flecs trait is a field
(`sparse`, `exclusive`, `transitive`, `cleanup`, `one_of`, `with`, …):

```zig
_ = world.component(Likes, .{ .storage = .sparse, .exclusive = true });
```

### Entities & bundles

```zig
const e = world.spawn(.{
    Position{ .x = 1, .y = 2 },        // component value
    Active,                            // tag type
    flecs.childOf(parent),             // relationships, all in one call
    flecs.pair(Likes, bob),
});

e.set(Position{ .x = 9, .y = 9 });     // add-or-write
_ = e.get(Position);                   // ?*const T
e.ensure(Velocity).x = 5;              // get-mut, add if missing
_ = e.getMut(Velocity);                // ?*T, null if absent (never adds)
e.emplace(Velocity).* = .{...};        // get raw storage, construct in place
e.toggle(Velocity, false);             // disable without removing
var r = e.ref(Position);               // cached ref: fast repeated r.get()
_ = e.clone(true); e.clear(); e.destroy();

// reusable bundles + bulk SoA spawn
const Enemy = flecs.bundle(.{ Health{ .hp = 100 }, Collider{}, Active });
_ = world.spawn(Enemy ++ .{Position{ .x = 0, .y = 0 }});
_ = world.spawnMany(1000, .{ .pos = positions_slice, .vel = Velocity{} });
```

### Queries

The row struct *is* the query - named, typed fields, declared inline:

```zig
var q = try world.query(struct {
    e:     flecs.Entity,
    pos:   *Position,                              // read-write
    vel:   *const Velocity,                        // read
    boost: ?*const Boost,                          // optional
    _:     flecs.Without(Dead),                    // filter
    pub const sort = flecs.ascBy(Position, .y);    // config as decls
});
defer q.deinit();

var it = q.iter();
defer it.deinit();                                 // idempotent; early break is safe
while (it.next()) |row| row.pos.x += row.vel.x;

var t = q.tableIter();                             // per-table SoA slices
while (t.next()) |tab| for (tab.pos, tab.vel) |*p, v| p.x += v.x;
```

Full operator set as wrapper fields: `With` · `Without` · `Or` ·
`AndFrom`/`OrFrom`/`NotFrom` · `Up`/`Cascade` (traversal) · `Singleton` ·
`From("Entity", ...)` (fixed source) · `Scope(.not, .{...})` · `Pair(R, ...)`
(wildcard + matched target). Plus `pub const group`, `pub const cache`, the
tuple form `world.query(.{ *Position, *const Velocity })`, change detection
(`q.changed()`), introspection (`q.count()`, `q.isTrue()`), JSON (`q.toJson`),
and `world.queryExpr("...")` (DSL hatch) — which also carries **named query
variables**: `q.findVar("friend")` + `it.setVar(v, entity)` to constrain a
`$var` before iterating.

Iteration has more modes: `q.pageIter(offset, limit)` (a windowed slice),
`q.workerIter(index, n)` (manual sharding across threads), and on a grouped
query `it.setGroup(id)` / `it.skip()` / `q.groupInfo(id)`.

### Systems

```zig
fn move(dt: flecs.Delta, pos: *Position, vel: *const Velocity) void { ... }
_ = world.system(.on_update, move);                          // bare function

const Gravity = struct {                                     // struct form + config
    pub const phase = .on_update;
    pub fn each(p: *Position, v: *Velocity, dt: flecs.Delta) void { ... }
};
_ = world.add(Gravity);

const Spawner = struct {                                     // stateful (closure-like)
    elapsed: f32 = 0,
    pub fn each(self: *@This(), dt: flecs.Delta, _: *Position) void { self.elapsed += dt.s; }
};
_ = world.add(Spawner{});                                    // instance persists
```

**Run-systems** drive their own iteration with `Query`/`Stage`/`Res`/`ResMut`
params - multi-query, nested loops, deferred structural change:

```zig
fn collide(
    ships: flecs.Query(struct { e: flecs.Entity, pos: *const Position, _: flecs.With(Ship) }),
    rocks: flecs.Query(struct { pos: *const Position, _: flecs.With(Asteroid) }),
    score: flecs.ResMut(Score),
    stage: flecs.Stage,
) void {
    var si = ships.iter();  defer si.deinit();
    while (si.next()) |s| { ... stage.destroy(s.e); score.v.points += 10; }
}
```

### Observers & events

```zig
fn onSpawn(_: flecs.OnSet(Position), e: flecs.Entity, p: *const Position) void { ... }
_ = world.observe(onSpawn);

// custom events with a payload (the *const E param is the event data)
const Damage = struct { amount: u32, crit: bool };
fn onHit(_: flecs.OnEvent(Damage), hp: *Health, d: *const Damage) void { hp.hp -|= d.amount; }
_ = world.observe(onHit);
world.emit(Damage{ .amount = 10, .crit = true }, .{ .target = e });   // or stage.enqueue

// monitors fire on enter/exit a query; observeOpts also has yield_existing
_ = world.observeOpts(onAlive, .{ .monitor = true });
```

### Relationships, prefabs, pipelines

```zig
alice.addPair(Likes, bob);
alice.setPair(Owes{ .gold = 30 }, bob);     // pair with data
alice.removePair(Likes, bob);               // (also ensurePair for get-mut)
var ts = alice.targets(Likes);              // iterate all targets
alice.addEnum(Team.red);                    // enum components -> (Team, .case)

const Fighter = world.prefab(.{ .name = "Fighter", .with = .{ Health{ .hp = 100 }, flecs.autoOverride(Position) } });
const grunt = world.spawn(.{ flecs.isA(Fighter), Position{ .x = 5, .y = 5 } });

const ai = world.phase(.pre_update);        // custom phases (dependency chain)
const movement = world.phaseAfter(ai);
_ = world.systemIn(movement, moveSys);
const timer = world.timer(0.5);             // shared tick source
world.setTickSource(aiSystem, timer);
```

### Reflection, JSON & Script

```zig
const Agent = struct {
    name: [:0]const u8, speed: f32, heading: Dir, waypoints: [3]f32,
    pub const flecs_units  = .{ .speed = flecs.units.MetersPerSecond };
    pub const flecs_ranges = .{ .speed = .{ .min = 0, .max = 300 } };
};
_ = world.reflect(Agent);
const json = try world.toJson(Agent{ ... }, allocator);     // also entity/world JSON

try world.script(
    \\Turret { Position: {10, 20}  Velocity: {1, 0} }
);                                                          // + managed loadScript

try world.scriptWith(                                       // bind Zig values as $vars
    \\Spawn { Position: {$x, $y} }
, .{ .x = @as(f32, 42), .y = @as(f32, 7) });

var cur = world.metaCursor(Agent, &value);                  // field-by-field at runtime
try cur.push(); try cur.member("speed"); try cur.set(@as(f32, 5)); try cur.pop();
```

Plus the **Explorer**: `world.enableRest(.{})`, `world.importStats()`,
`entity.setDoc(.{ .brief = ... })`, `world.alert(.{...})`, `world.metric(...)`.

### Modules & extensions

```zig
const physics = struct {
    pub const Gravity = struct { g: f32 = 9.81, pub const flecs_traits: flecs.Traits = .{ .singleton = true } };
    pub fn integrate(dt: flecs.Delta, p: *Position, v: *Velocity, g: flecs.Singleton(*const Gravity)) void { ... }
    pub fn init(world: anytype) !void { world.set(Gravity{}); _ = world.system(.on_update, integrate); }
};
try world.import(physics);

// extensions graft a typed namespace onto the world type
var world = try flecs.World(.{ .ext = .{spatial} }).initExt(.{}, .{spatial.Options{ .cell = 32 }});
const cs = world.ext(spatial).cellSize();
```

### Threading & runtime

`flecs.runtime(...)` is process-global; call it once at startup, before any world.

```zig
// built-in worker threads
var world = try flecs.World(.{}).init(.{ .threads = 4 });
_ = world.systemOpts(.on_update, move, .{ .multi_threaded = true });

// route all allocations through a Zig allocator
flecs.runtime(.{ .allocator = my_gpa });

// pure-std platform layer (no libc/pthread threading dependency)
flecs.runtime(.{ .threading = .std });
var world = try flecs.World(.{}).init(.{ .task_threads = 4 });

// run flecs' parallel pipeline on a std.Io executor
flecs.runtime(.{ .io = threaded.io() });
var world = try flecs.World(.{}).init(.{ .task_threads = 4 });

// manual staging: record structural changes off-thread, then merge
world.setStageCount(n);
_ = world.readonlyBegin(true);
//   worker i drives world.stage(i) (itself a world handle) ...
world.readonlyEnd();                 // merges every stage
```

Other knobs: `world.setTimeScale` (slow-mo/pause), `resetClock`, `dim`
(preallocate), `measureFrameTime`; entity-id management for networking
(`world.makeAlive`, `getAlive`, `e.exists()`, `e.isValid()`); and
`flecs.log.setLevel(...)` / `enableColors(...)` for flecs' log output.

### Advanced / low-level

For systems work that needs to reach under the abstraction:

```zig
// async stage: queue commands off-thread, merge when ready
var s = world.asyncStage();
flecs.Entity.init(s.raw, e.id).set(Position{ ... });
s.merge();  world.freeStage(s);

// exclusive access: assert single-thread ownership (debugging cross-thread bugs)
world.exclusiveAccessBegin("main");  defer world.exclusiveAccessEnd(false);

// fast locked single-entity access (skips per-component lookups)
var w = e.write().?;  w.get(Position).?.x += 1;  w.end();

// archetype inspection: the table (SoA storage) an entity lives in
const t = e.table().?;
for (t.column(Position).?) |*p| p.x = 0;     // whole column at once

// maintenance / introspection
world.setWith(Tag);                          // auto-add Tag to new entities (scoped)
_ = world.deleteEmptyTables(.{ .delete_generation = 5 });
world.shrink();                              // return reserved memory to the OS
const all = world.entities();                // snapshot of every id

// archetype graph + bulk placement, dynamic value construction
const t2 = e.table().?.with(Tag);            // archetype reachable by adding Tag
_ = world.spawnInTable(t2);                  // create straight into an archetype
e.moveTo(t2);                                // move an entity between archetypes
world.valueInit(T, &scratch);                // run T's ctor on raw storage
```

The flecs feature set is wrapped end-to-end; the raw C bindings are an internal
detail and are **not** re-exported, so application code never drops to C.

## Examples

`zig build run-<name>` - each is self-contained and prints a verifiable result.

| | | |
|---|---|---|
| `hello` | `entity` | `component` |
| `query_basics` | `query_advanced` | `relationship` |
| `system_each` | `system_run` | `system_threaded` |
| `observer_events` | `prefab` | `bundle` |
| `pipeline` | `module` | `reflect_json` |
| `script` | `explorer` | |
| `runtime_allocator` | `runtime_std_threads` | `runtime_io` |

## Status

The binding wraps the full flecs 4.1.1 feature set - core ECS, queries,
systems/observers, relationships, prefabs, pipelines, reflection/JSON/Script,
staging, tables, and the addons - behind idiomatic Zig. The raw C API is **not**
exposed; everything is reachable through the typed surface above.

Known edges:
- **Named query variables** live on the `queryExpr` DSL path (`findVar` +
  `it.setVar`); a variable binds *across* terms, so it has no place in a single
  comptime struct field of a typed query.
- **String opaque** serializes to JSON but doesn't deserialize (ownership).
- **TreeSpawner** has no public C API in flecs 4.1.1 - nothing to bind.
- **Multi-world** is supported sequentially; concurrent worlds sharing the static
  component-id cache are not. The `flecs.runtime` knobs are one-shot by design.
- Requires **Zig 0.16**.

## Layout

```
build.zig            module + flecs C compilation + tests/examples
build.zig.zon        flecs v4.1.1 pulled as a package dependency
src/
  root.zig           public API surface
  world.zig          World(cfg) builder + the world API
  entity.zig         Entity handle
  meta.zig           component registration, traits, enum/id helpers
  terms.zig          query term wrappers + sort specs
  bundle.zig         spawn-bundle items
  compile.zig        shared term compiler (queries + systems)
  query.zig          typed Query(Row), iteration, untyped Expr
  system.zig         each-/run-/stateful-system & observer trampolines
  stage.zig          deferred command target
  events.zig         custom event emission
  reflect.zig        @typeInfo -> EcsStruct meta, JSON
  meta_cursor.zig    runtime field-by-field reflection cursor
  units.zig          typed unit-entity accessors
  log.zig            flecs logging controls
  addons.zig         doc / json / app / units / bitmask / alerts / metrics
  runtime.zig        allocator + pure-std / std.Io platform injection
  tests.zig          executable spec
examples/            20 self-contained, runnable examples
```

## License

The binding follows the flecs license (MIT). flecs © Sander Mertens.
