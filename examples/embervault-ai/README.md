# Embervault Underhall — AI asset example

[中文绘制过程](README.zh-CN.md)

![Embervault Underhall](preview.png)

A furnished underground hall built with the Dungeondraft MCP Bridge, using eleven text-generated transparent sprites and Dungeondraft's built-in architecture. This is the **artistic layout**: furniture is enlarged for readability, with consistent sizes within each class and a navigable central aisle. It is not a real-scale architectural plan.

## Open and use

Open [Embervault-Underhall-AI.dungeondraft_map](Embervault-Underhall-AI.dungeondraft_map) in Dungeondraft 1.2.0.1. No external asset pack is required. All eleven custom images are embedded, and the 100 placed objects remain independently movable and resizable. The parchment and tools painted into the table sprite are part of that image, not separate editable objects. Floors, walls, doors and lights use native elements. The bridge is required for automated validation, not for manually opening the map.

- [Clean map PNG](Embervault-Underhall-AI.png): 2112 × 3840 pixels, 96 pixels per grid square.
- [Grid map PNG](Embervault-Underhall-AI-grid.png): the same resolution, with a visible grid.
- [Assets and full prompts](assets-manifest.json): generation method, alpha crop, import dimensions and SHA-256 hashes.
- [Layout sidecar](layout.json): coordinates, class sizes, roles, floor polygons, light parameters and session spatial zones.
- [Checks](checks.json): geometry, navigation, packaging and save/reopen results.

## Drawing process

1. **Plan architecture before furniture.** Use a 22 × 40 tile canvas (256 world pixels per tile). Connect a central hall, northern store and southern vault. Four octagonal corner chambers contain descending spiral stairs. Their upper landings face the connecting passages: the sprite's entrance points east in the western chambers and is rotated 180° in the eastern chambers. The lower floor itself is not included. Side work/dining/sleeping areas stay outside the central route.
2. **Generate individual props from text.** Create stairs, tables, stools, barrels, pillars, crates, chandeliers, beds, torches, a hearth and shelves. Each prompt specifies an orthographic overhead view, transparent background, dark contours, aged oak/bronze/slate colors and no external cast shadow. No third-party map or asset was supplied to generation. Inspect alpha, crop to the alpha > 10 bounds and proportionally resize to at most 512 pixels with Lanczos. This preparation changes size and transparent margins; it does not repaint the artwork. Import each PNG through `import_image` as an embedded object.
3. **Build native floors and openings.** Draw floor polygons with `Level.FloorShapes.DrawPolygon`, select the native Smart Stone tile ID 1 and populate `Level.TileMap.AddRect`. Remove only the automatically created duplicate walls; retain independent wall polylines with intentional corridor openings. Use the built-in stone wall and door textures. Widen the stair connectors to two tiles, and keep two native wall-mounted doors. A tileset picker alone did not update the active smart tile; explicitly selecting `set_SmartTileId` resolved the floor mismatch.
4. **Arrange by furniture class and role.** Apply repeated class sizes rather than random per-object scaling. Place the tables in functional bays, with stools around accessible sides, shelves beside partitions, and storage clear of stair landings. Use furniture layer 200, overhead chandeliers 300 and masonry pillars 400. Pillars intentionally meet walls; chandeliers are overhead and therefore do not occupy floor walking space. Neither exception is applied to ordinary furniture.
5. **Check the whole footprint.** Check alpha-trimmed rotated rectangular envelopes against walls, rooms, other ground objects, door clearance and reserved paths. Twelve initial placements failed these conservative checks; reposition the crates/barrels/beds instead of disabling ordinary furniture validation or shrinking individual objects to hide the conflict. Explicit ceiling/structural roles use a separate audit before their intentional overlaps are permitted.
6. **Test movement, then repair bottlenecks.** Flood-fill on a 0.125-tile grid from the southern entrance, using native wall widths, open door intervals and full furniture envelopes. A 0.4-tile actor passed initially, but a one-tile combat token exposed three blocked destinations. Move the private workshop table, nearby crate/stools and lower-right dining arrangement, with their chandelier/light anchors. All thirteen destinations subsequently pass at both widths. The test targets the stair landings, not movement through a stair shaft.
7. **Attach lights to visible sources.** Use nine chandeliers, six torches and one hearth: sixteen enabled, shadow-casting native lights. Ambient color is `#99918b`; chandeliers use `#ffd09b`, energy 0.65, range 1.9–3.1; torches use `#ffba78`, energy 0.45, range 2.5; the hearth uses `#ffad65`, energy 0.6, range 2.3. Range is a texture scale, not a world-distance radius. Overlapping bright lights initially washed out the floor, so lower their energy and inspect a native export. Walls and tall pillars occlude light; low furniture does not block the ceiling lights. This uses Dungeondraft's two-dimensional lighting, not a three-dimensional inverse-square simulation.
8. **Save, reopen and package.** Verify native object positions, sizes, rotations, layers, two doors and sixteen lights after reopening. Deduplicate the initial 100 embedded copies into eleven shared image entries without merging placed objects. Remove unused installed-pack metadata and unused tileset lookup entries; keep every tile ID actually used. Confirm the map has no external pack references or local source paths. Export the final clean and grid PNGs from Dungeondraft and visually inspect the result.

## Sizes and verification boundaries

The longest sprite dimension is the class size recorded in `layout.json`; it includes the technical alpha crop. Stools and barrels are 0.55 tiles, crates 0.7 tiles, beds 1.85 tiles and stairs 2.6 tiles. Table length varies deliberately from 2.1 to 3.1 tiles by bay; pillars and overhead fixtures use architectural sizes suited to their location. The map retains usable circulation while giving props enough visual weight to read at a glance.

Spatial room/clearance zones are **session metadata**: reopening the native map clears them. From the repository's installed Python environment, with this sample open and the bridge running, execute:

```powershell
python examples/embervault-ai/validate_live.py
```

The validator checks map size/object IDs before restoring its zones, then checks object transforms, role-aware geometry, all thirteen navigation destinations at both widths and sixteen light sources. It writes `live-checks.json`. It does not rearrange furniture. Conservative rectangular footprints can report false positives for concave sprites; intentional pillar/wall contacts are recorded separately. This sample covers an indoor map workflow, not every terrain, elevation or software feature.

The sample exposed a bridge bug: editing wall geometry through the native `Wall.Set` path deleted mounted portals. The updated `modify_wall` preserves portal nodes and their relative segment anchors, updates their orientation and rejects topology changes or segments too short to contain a portal **before** changing tint/texture. The opt-in `tests/live_wall_portals.py --run-live` uses a separate fixture and restores the previously open map; it checks a door and window, state/orientation, safe rejection and native save/reopen.

## Artwork and provenance

The eleven custom sprites were created through native ImageGen with text-only prompts. Prompts and import hashes are included for inspection and regeneration; image generation is not deterministic. The generated sprites and sample support files are offered under [MIT](LICENSE), to the extent copyright applies. Built-in Dungeondraft artwork remains its owner's property; it is referenced by the native map and appears in rendered maps, but is not distributed here as standalone stock art. Dungeondraft's [official FAQ](https://dungeondraft.net/) permits publishing original maps. The software itself is not included.
