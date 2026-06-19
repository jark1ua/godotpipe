# Per-layer terrain textures

Drop dedicated PBR maps for a layer into its folder here. The streamer
(`TerrainStreamer.gd`) builds the Texture2DArrays from these at runtime.

## How resolution works (per layer, per map)
For each of the 32 layers and each map (albedo, normal, height, ao, rough):
1. `arrays/layers/<NN_name>/<map>.png`  ← dedicated (this folder) — used if present
2. `arrays/sets/<texture_set>/<map>.png` ← base set fallback (currently grass/rock/snow/sand)
3. solid colour                          ← last-resort fallback

So you can override just one map for one layer (e.g. a custom `albedo.png`) and the
rest inherit the base set. Until you add files here, every layer uses its base set.

## Files to add per layer (all optional, all 2K, same size within a map)
- `albedo.png` — sRGB
- `normal.png` — OpenGL Y+ (import as Normal Map)
- `height.png` — grayscale, linear (drives parallax depth + seam blending)
- `ao.png`     — grayscale, linear (Non-Color)
- `rough.png`  — grayscale, linear (Non-Color)

Folder names are `<zero-padded index>_<manifest name>` and must match
`control_map_layers.json` (the streamer derives the path from index + name).

## Layers
| folder | group | tile_m | triplanar | base set |
|---|---|---|---|---|
| `00_rock_cold_granite` | rock | 12 | true | rock |
| `01_rock_warm_sandstone` | rock | 12 | true | rock |
| `02_rock_basalt_volcanic` | rock | 10 | true | rock |
| `03_rock_limestone` | rock | 12 | true | rock |
| `04_rock_shale_slate` | rock | 10 | true | rock |
| `05_grass_lush_meadow` | grass | 8 | false | grass |
| `06_grass_dry_dead` | grass | 8 | false | grass |
| `07_grass_sparse_thin` | grass | 8 | false | grass |
| `08_grass_moss_wet` | grass | 6 | false | grass |
| `09_heather_shrubland` | grass | 8 | false | grass |
| `10_snow_fresh_powder` | snow | 10 | false | snow |
| `11_snow_packed_ice` | snow | 12 | false | snow |
| `12_snow_ash_white` | snow | 10 | false | snow |
| `13_sand_fine_beach` | sand | 6 | false | sand |
| `14_sand_coarse_shell` | sand | 6 | false | sand |
| `15_sand_dune` | sand | 10 | false | sand |
| `16_forest_floor_conifer` | forest | 8 | false | grass |
| `17_forest_floor_deciduous` | forest | 8 | false | grass |
| `18_fern_undergrowth` | forest | 6 | false | grass |
| `19_dead_leaves_autumn` | forest | 6 | false | grass |
| `20_scree_loose` | gravel | 6 | true | rock |
| `21_pebble_field` | gravel | 5 | false | rock |
| `22_shale_broken_slate` | gravel | 8 | true | rock |
| `23_mud_riverbed` | wet | 6 | false | sand |
| `24_swamp_bog` | wet | 6 | false | grass |
| `25_wet_moss` | wet | 6 | false | grass |
| `26_saltmarsh_tidal` | wet | 6 | false | sand |
| `27_volcanic_ash` | special | 8 | false | rock |
| `28_charcoal_burnt` | special | 8 | false | rock |
| `29_salt_flats` | special | 10 | false | snow |
| `30_bone_field` | special | 8 | false | snow |
| `31_lichen_exposed_bedrock` | special | 10 | true | rock |
