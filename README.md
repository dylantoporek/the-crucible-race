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
| Toggle HUD | F1 | |

## What is in the prototype

- **Raycast vehicle** (`scripts/car/raycast_car.gd`): four suspension rays with spring
  and damper, a slip-angle tyre curve, friction circle, anti-roll bars, quadratic drag,
  light downforce, handbrake, reverse, self-righting when airborne or flipped, and
  contact-impulse hit detection.
- **Surface system** (`scripts/surfaces/`): every drivable body carries a `surface`
  meta tag. Each `SurfaceType` defines grip, lateral grip, rolling resistance,
  soft-surface sink, bumpiness and dust. Asphalt, dirt, sand, ice, snow and grass are
  registered in `surface_library.gd`. Add a terrain by adding one line there.
- **Procedural test circuit** (`scripts/track/test_track.gd`): a 2.3 km closed loop
  extruded from a spline, split into surface segments in the order asphalt, dirt,
  asphalt, sand, asphalt, ice, snow, asphalt, dirt. Each change of surface happens
  through a 36 m blend zone of six intermediate grip bands, placed on the straightest
  nearby road, and marked with white lines at both ends. Grass shoulders, barrier
  walls, start gate, and crates to knock about.
- **AI opponents** (`scripts/car/ai_driver.gd`): spline followers that slow for
  corners and low grip, hold a lane, and lean on the player when alongside.
- **Chase camera** that follows the velocity vector so slides read on screen, with
  hit shake.
- **Debug HUD** with speed, current surface, grip usage, per-wheel telemetry, laps,
  position and hit count.
- **Cel shader** (`shaders/toon.gdshader`) that works on the Compatibility renderer.

## Tuning

All the numbers that matter are exported on the car scene. The ones to reach for
first:

| Feel | Property |
|---|---|
| Quicker / slower | `max_engine_force`, `top_speed`, `drag_coefficient` |
| More / less grip | `tyre_grip`, or per surface `grip` in `surface_library.gd` |
| Throttle pushes wide vs. holds line | `longitudinal_grip`, `min_drive_fraction` |
| Tail wags / settles | `yaw_damping` |
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
scripts/track/ test_track (procedural circuit)
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
2. Point-to-point course builder with biome chunks streamed along the spline.
3. Proper car model, outline pass, skid marks, engine and surface audio.
4. Smarter AI: overtaking, blocking, rubber-banding, grudges.
5. Native desktop exports alongside the web build.
