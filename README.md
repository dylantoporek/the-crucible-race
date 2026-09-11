# The Crucible Race

A cross-biome contact racer. One long course through sand, dirt, asphalt, ice and snow,
a pack of cars that would rather trade paint than give you room, and a finish line at the
end of it. Physics are realistic underneath and arcade on top, in the spirit of Wreckfest.
The look is heading toward cel-shaded / anime.

Built with **Godot 4.7** (GDScript, Jolt physics, Compatibility renderer) so the same
project runs natively and in the browser.

## Play it

**In the editor:** open the folder in Godot 4.7.x and press Play (F5).

**Headless smoke test** (also runs in CI):

```
godot --headless --path . res://tests/smoke_test.tscn
```

**Web build:** every push to `main` or a `claude/**` branch runs
`.github/workflows/deploy-web.yml`, which runs the smoke test and exports the Web preset.
Pushes to `main` also publish it to GitHub Pages; other branches only produce the
downloadable artifact. The first run enables Pages automatically where permissions allow. If the
deploy job fails on that step, turn Pages on once under
*Settings → Pages → Source: GitHub Actions* and re-run the workflow. The link is then
`https://<owner>.github.io/the-crucible-race/`.

GitHub Pages needs the repository to be public, or a paid GitHub plan for a private
repository. Until then, every workflow run still uploads the finished build as the
`web-build` artifact on the run's summary page. Download it, unzip it, and serve the
folder with any static server, for example:

```
python3 -m http.server 8000
```

then open `http://localhost:8000/`.

To export locally you need the 4.7.1 export templates installed, then:

```
godot --headless --path . --export-release "Web" build/web/index.html
```

## Controls

| Action | Keyboard | Gamepad |
|---|---|---|
| Throttle | W / Up | Right trigger |
| Brake (reverse when stopped) | S / Down | Left trigger |
| Steer | A / D, Left / Right | Left stick |
| Handbrake | Space | X |
| Reset to track | R | Y |
| Restart the field at stage 1–6 | 1–6 | |
| Toggle HUD | F1 | |

The race starts with a READY / SET / GO hold of about two and a half seconds, on the
initial grid and after every stage restart; the player lines up at the back of the pack.

For testing a particular stretch, `?stage=3` (or `?stage=mountain`) on the web build's URL
drops the whole field onto a grid at that stage's start, so a link can point straight at
the part of the course under discussion.

## What is in the prototype

- **Raycast vehicle** (`scripts/car/raycast_car.gd`): four suspension rays with spring
  and damper, a slip-angle tyre curve, friction circle, anti-roll bars, quadratic drag,
  light downforce, handbrake, reverse, self-righting when airborne or flipped, and
  contact-impulse hit detection.
- **Surface system** (`scripts/surfaces/`): every drivable body carries a `surface`
  meta tag. Each `SurfaceType` defines grip, lateral grip, rolling resistance,
  soft-surface sink, bumpiness and dust. Asphalt, dirt, sand, ice, snow and grass are
  registered in `surface_library.gd`. Add a terrain by adding one line there.
- **Generated sprint course** (`scripts/track/sprint_track.gd`, `route_spec.gd`): an
  8.5 km point-to-point run through six stages — badlands dirt, a village, a wide ruined
  desert, a climbing city, a mountain pass and the descent into the arena. The route is
  generated from a stage table rather than hand-placed control points, so changing the map
  means editing data. Road width, surface mix, corner tightness, gradient and hazards are
  all per stage. Each change of surface happens through a 34 m blend zone of six
  intermediate grip bands, marked with white lines at both ends.
- **AI opponents** (`scripts/car/ai_driver.gd`): spline followers that slow for
  corners and low grip, hold a lane, and lean on the player when alongside.
  The demo grid is 16 cars (`ai_count` on the main scene).
- **Chase camera** that follows the velocity vector so slides read on screen, with
  hit shake.
- **Debug HUD** with speed, current surface, grip usage, per-wheel telemetry, laps,
  position and hit count.
- **Cel shader** (`shaders/toon.gdshader`) that works on the Compatibility renderer.

## Performance

Physics is the limit, not rendering: each car is only 7 draw calls, but its wheel
raycasts, tyre forces and AI cost CPU every tick. Measured headless on a 2.1 GHz Xeon,
where the budget for 60 Hz is 16.67 ms per tick:

| Course | Cars | Physics per tick | Share of budget |
|---|---|---|---|
| old 2.3 km circuit | 16 | 2.7 ms | 16% |
| sprint course | 16 | 5.4 ms | 32% |

Each car costs about 0.12 ms; the rest is the course itself, which carries around 570
static bodies against the circuit's ~115. The web build is single threaded and WebAssembly runs
slower than native, so treat these as roughly what a mid-range laptop sees in a browser.
Around 20 cars is the practical browser ceiling today; a physics level of detail pass
(full simulation only near the player) is what would take it past 40.

Track offsets are the reason this is affordable. `TestTrack.track_offset()` caches one
offset per body per physics frame and finds it by searching a 12 m window around where
the body was last tick, instead of scanning all 2,292 baked points of the curve. It falls
back to the full scan on a cache miss or when a body is reset or teleported.

## Changing the map

Everything about the course lives in `scripts/track/route_spec.gd`. Each stage declares how
long it lasts, how wide the road is, which surfaces it mixes and what hazards it carries.
Two fields do most of the work:

- **`min_radius`** — the tightest corner on the stage, in metres. The S-bend amplitude is
  derived from it, so you cannot accidentally author a hairpin no car could take. A corner
  taken flat out needs roughly `speed² / (1.15 · grip · 9.81)` metres.
- **`max_grade`** — the steepest gradient allowed. The climb takes its share first and
  rolling hills get whatever is left, so a stage can never out-climb its own grip. The
  ceiling is about `1.15 × grip`: asphalt ~115%, dirt ~76%, sand ~63%, snow ~47%, ice ~23%.

Hazards are declared per stage under `features`: `moguls` (folded into the road mesh, good
for air), `ruin_halls` (the road runs under a broken roof with a colonnade down the centre,
splitting it into two lanes), `pillars` (free-standing columns with a gap that sways across
the road), `fallen_columns`, `ice_patches` (scattered over snow, and kept off gradients ice
cannot pull away from), `rocks`, `buildings`, `arena` stands, a `pit_apron`, and loose
`debris`. Where hazards leave only a gap, the track publishes it via `hazard_gate()` and
the AI threads it rather than driving into a column; inside a hall it commits to whichever
lane it is already on, starting 70 m before the first column.

## Tuning

All the numbers that matter are exported on the car scene. The ones to reach for
first:

| Feel | Property |
|---|---|
| Quicker / slower | `max_engine_force`, `top_speed`, `drag_coefficient` |
| More / less grip | `tyre_grip`, or per surface `grip` in `surface_library.gd` |
| Easier / harder to spin under power | `lateral_priority` (0 = throttle steals cornering grip, 1 = never) |
| Throttle pushes wide vs. holds line | `longitudinal_grip`, `min_drive_fraction` |
| Tail wags / settles | `yaw_damping` |
| How much grip is left mid-slide | `slide_falloff` |
| Softer / harsher surface changes | `surface_blend_time` on the car, `transition_length` on the track |
| Sharper turn-in | `max_steer_deg`, `steer_speed`, `peak_slip_angle_deg` |
| Slidier handbrake | `handbrake_lateral_grip` |
| Softer / stiffer ride | `spring_stiffness`, `damping_*` on each wheel |
| Less body roll | `anti_roll`, `center_of_mass` |
| Sand feels heavier | `sink_drag` on the car, `sink` on the surface |

## Layout

```
scenes/        main.tscn (session), car.tscn (vehicle)
scripts/car/   raycast_car, car_wheel, player_driver, ai_driver
scripts/track/ sprint_track (generator + builder), route_spec (the map, as data)
scripts/surfaces/  surface_type, surface_library (autoload `Surfaces`)
scripts/camera/    chase_camera
scripts/ui/        debug_hud
scripts/game/      game (spawning, laps, positions)
shaders/           toon.gdshader
tests/             smoke_test (headless physics check)
.github/workflows/ deploy-web.yml
```

## Roadmap

1. Damage: mesh deformation from contact impulses, detachable panels, performance loss.
2. Pit stop mechanics — the apron and bays exist as geometry, but stopping does nothing yet.
3. Terrain under the course. Today there is one flat plate beneath everything, so an
   elevated stage reads as a ridge standing on a plain rather than a real mountain.
3. Proper car model, outline pass, skid marks, engine and surface audio.
4. Smarter AI: overtaking, blocking, rubber-banding, grudges.
5. Native desktop exports alongside the web build.
