# Farm Route Planner

A World of Warcraft (WoW Forever) addon for planning and running gathering routes.
You draw a route on a zone map, or have one built from your GatherMate2 nodes. The
route then shows on the minimap (including FarmHud) and the world map, and TomTom can
walk you through it.

## Features

- **Its own planner window** opens on your current zone, with a dropdown of every zone and the real zone map art.
- **Click-to-draw routes:** click to add a point and drag a point to move it. Click a point to select it (it turns green) and new points go after it; right-click a point to delete it. Undo works for every edit.
- **Saved routes with names**, one list per zone. Tick a route to show it.
- **Minimap and FarmHud display:** each route shows as a line with direction arrows. It's drawn with HereBeDragons, the same library GatherMate2 uses for its icons, so it lines up with the nodes.
- **World map display:** saved routes show on the zone and continent maps.
- **GatherMate2 integration:**
  - Your GatherMate2 nodes are shown on the planner map.
  - You can turn node types and individual nodes (Copper Vein, Peacebloom, ...) on or off.
  - **GatherMate Optimized Route** builds a short loop through every chosen node.
- **Record Path:** the addon drops a point every few yards as you walk. Use it to record the real path between two nodes of an optimized route.
- **TomTom follow mode:** the TomTom arrow moves to the next point once you're within a distance you choose.
- **Range ring:** a ring around you on the minimap, 185 yards by default (about the Find Minerals / Find Herbs range). Pick another size, or match GatherMate2's tracking distance.
- **Import / Export:** share routes as text strings.

## Install

1. Download the latest release from [CurseForge](https://www.curseforge.com/wow/addons/farm-route-planner), [Wago](https://addons.wago.io/addons/farm-route-planner), or the [GitHub Releases page](https://github.com/BGannon2/FarmRoutePlanner/releases).
2. Extract the `FarmRoutePlanner` folder into `World of Warcraft\_forever_\Interface\AddOns\`.
3. Optional companions: GatherMate2, TomTom, FarmHud.

## Using it

Open the planner with the map button on the minimap (left-click) or `/frp`.
Right-clicking the minimap button starts or stops TomTom following.

| Command | What it does |
|---|---|
| `/frp` | Open or close the planner |
| `/frp follow [name]` | Follow a saved route in this zone with TomTom |
| `/frp stop` | Stop following |
| `/frp dist 25` | Distance (yards) at which the arrow moves to the next point |
| `/frp record` | Start or stop recording a path |
| `/frp ring [yards]` | Turn the range ring on or off, or set its size |
| `/frp minimap` | Show or hide routes on the minimap |
| `/frp button` | Show or hide the minimap button |
| `/frp exportall` | Export every saved route as one string |
| `/frp debug` | Print diagnostic information |

## GatherMate2 data

GatherMate2 only knows nodes you've gathered or imported. To import its bundled data,
type `/gm`, open **Import Data**, tick the node types, and click **Import** (choose **Merge**).

## Releasing (maintainers)

Pushing a tag such as `v1.0.0` runs the GitHub Actions workflow in
`.github/workflows/release.yml`. It uses the [BigWigs packager](https://github.com/BigWigsMods/packager)
to build the zip, create a GitHub release, and upload to CurseForge and Wago.

The project IDs are already in `FarmRoutePlanner.toc` (`## X-Curse-Project-ID:` and `## X-Wago-ID:`).
Each site's API token must be stored as a repository secret: `CF_API_KEY` and `WAGO_API_TOKEN`.

## License

MIT. See [LICENSE](LICENSE).
