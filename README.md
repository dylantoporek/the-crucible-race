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
| Reset to track (rolling restart) | R | Y |
| Jump | C or Left Ctrl | B |
| Use gadget | Shift or E | A |
| Change gadget (after a pit stop) | Q / Tab | LB / RB |
| Restart the field at stage 1–7 | 1–7 | |
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
  9.1 km point-to-point run through seven stages — badlands dirt, a village, a wide ruined
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

## Damage, repairs and gadgets

- **Getting going again.** Reset drops the car back in the middle of the road, pointing
  down it, already rolling at about 40 mph, with 2.5 s of immunity so the pack cannot wipe
  it out before it has moved. The car blinks while that lasts. Where the middle is blocked
  — a hazard field, or the colonnade down a ruined hall — it takes the centre of the clear
  lane, and on an alternative route it uses that route's middle. The AI's stuck-car
  watchdog recovers the same way, so a reset opponent is never a stationary obstacle.
  `RESET_SPEED` and `RESET_INVULN` in `scripts/car/raycast_car.gd`.
- **Damage.** Every car has 100 health. Sideways and head-on impacts take it away —
  landing a jump does not — and what a hit costs depends on how fast you were going as
  well as how hard it landed: the same shunt at 34 m/s costs about three times what it
  does at 9 m/s, and no single hit costs more than 18. Walls and scenery cost 40% of what
  a car does.
- **Damage you can feel, not fight.** Anything above 50% health drives exactly like a
  fresh car; the paint darkens but nothing else changes. Below that the losses ramp in to
  their full value at zero: 15% of engine power, 6% of top speed, and a slight pull toward
  the side you were hit on. Smoke starts past 50%. Even a wrecked car keeps most of its
  pace, so a bad race is a handicap rather than a retirement. The whole model is the
  Damage group in `scripts/car/raycast_car.gd`; `damage_grace` is the "nothing happens
  above this" line, and `handling_penalty()` is what the physics reads.
- **Repair stations / pits.** One green pad per stage, seven in all, so no stretch of the
  course leaves you nursing a broken car for long. Drive onto one for a full repair; it
  costs you the racing line, and on a narrow road the pad is pulled in to the kerb so
  passing traffic is not healed by accident. AI below 45% health will divert to the next one. A pit stop
  also opens a 6 s window in which you can pick any gadget with Q / Tab (LB / RB); a car
  that arrives without one is handed one. Swapping keeps whatever cooldown you had.
- **Jump.** Every car has one, on its own button and its own 5 s cooldown, independent of
  whatever gadget it is carrying. It is there to get you out of the nonsense — a spinning
  car across the road, a crate, stopped traffic — so a pickup is always a real weapon
  rather than a hop you already had. `JUMP_COOLDOWN` in `scripts/car/raycast_car.gd`.
- **Gadgets.** A row of three glowing boxes sits across the road about every 480 m. The
  first car to drive through one that is not already armed takes it; a car that already
  holds a gadget passes straight through and leaves it. Boxes do not come back until the
  race restarts. A gadget is kept for the whole race and can be used again after a 20 s
  cooldown. Shift, E or the A button fires it.
- **Two kinds of opponent.** Every other grid slot is a **bruiser** (black bar across the
  nose): it leans on you when it is alongside and pits for a shield or oil. The rest
  are **racers**: they give everyone room, chase the win, and pit for boost or jump.
  Set in `_spawn_car` in `scripts/game/game.gd`.

| Gadget | What it does |
|---|---|
| Shield | 5 s of no damage; any car that touches you is thrown and takes damage. |
| Boost | 3 s of +75% engine power and +30% top speed. |
| Oil Slick | Drops a puddle behind you that drives like ice for 10 s. |

Definitions live in `scripts/gadgets/gadget_defs.gd`; effects in `scripts/car/gadget_slot.gd`.
`tests/gadget_test.tscn` exercises all of it headlessly and runs in CI.

## Cities and the village routes

- **City sections are technical.** Waypoint Village, Foothill City and the new final stage,
  Crucible City, use `jogs`: block corners of 45–80 degrees, a short straight, and the same
  corner back, alternating direction, on top of a tight S-bend wiggle (30–34 m minimum
  radius). The descent no longer runs straight to the flag: it hands over to Crucible City,
  a tight, falling run through tall buildings that opens into the stadium for the last
  straight.
- **Three ways through Waypoint Village.** A gantry 105 m before the fork names them, the
  HUD counts down to the split, and each route peels off at a real angle (`split_angle`)
  with the barrier opened from the fork itself and a striped kerb nose and route board on
  the divider — so the junction reads as a Y from the driver's seat rather than as a slot
  in a wall further along. Straight on is the **Old Town**: the main road, shortest,
  tightest. Right is the **Avenue**: wide and sweeping but longest. Left is the **Tunnel**:
  narrow, drops 11 m below street level under a roof. A clean AI lap of each is within
  about 15% of the others. Each route has its own gadget box row. The AI field splits a
  third each way. Positions and progress compare across routes because distance along a
  branch maps back onto the main road. Branches are declared per stage under `branches` in
  `route_spec.gd`.
- `tests/route_test.tscn` drives each route headlessly and checks it is drivable, tracked,
  about the same time as the others, that it peels clear of the main road within 30 m, and
  that the barrier opens at the fork.

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
tests/             smoke_test, gadget_test, route_test (headless checks, all run in CI)
tools/             dump_course (course geometry to JSON, for drawing maps)
.github/workflows/ deploy-web.yml
```

## Roadmap

1. Visual damage: mesh deformation and detachable panels on top of today's paint, tilt and smoke.
2. Pit stop mechanics beyond the repair pad — tyres, or a repair that takes time.
3. Terrain under the course. Today there is one flat plate beneath everything, so an
   elevated stage reads as a ridge standing on a plain rather than a real mountain.
3. Proper car model, outline pass, skid marks, engine and surface audio.
4. Smarter AI: overtaking, blocking, rubber-banding, grudges.
5. Native desktop exports alongside the web build.
