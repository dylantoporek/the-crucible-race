class_name RouteSpec
extends RefCounted
## The map, as data. Everything about the course's shape, surfaces, width and hazards
## lives in STAGES below; SprintTrack turns it into geometry. To change the course,
## change this table — nothing else needs touching.
##
## Per-stage keys
##   id / name        identifier and the label shown on the HUD
##   seconds / speed   stage length = seconds * speed (m/s expected pace on this terrain)
##   half_width        metres from centre line to the edge of the road
##   surfaces          [[surface_id, share], ...] — shares are normalised over the stage
##   turn              net heading change across the stage, degrees (+ right, - left)
##   min_radius        tightest corner on the stage, metres — this is the real control over
##                     how technical it feels. The S-bend amplitude is derived from it, so a
##                     corner no car could take is impossible to write by accident.
##   bend_len          wavelength of the S-bends, metres. Shorter = corners come at you faster.
##   tech              {from, to, min_radius, bend_len} — a tighter, more technical stretch
##   climb             net elevation change across the stage, metres
##   max_grade         steepest gradient allowed, as a fraction (0.18 = 18%). The rolling-hill
##                     amplitude is whatever is left of this budget after the climb takes its
##                     share, so a stage can never out-climb the grip available on its surface.
##   hills_wave        wavelength of the rolling hills, metres
##   features          hazards and scenery, see SprintTrack._build_features();
##                     "repair": {at, side} places a repair station at that fraction of the stage
##
## For reference, the steepest grade a surface can pull away on is roughly
## 1.15 * its grip: asphalt ~115%, dirt ~76%, sand ~63%, snow ~47%, ice ~23%.

const STAGES: Array[Dictionary] = [
	{
		"id": &"badlands", "name": "Badlands Run",
		"seconds": 60.0, "speed": 25.0, "half_width": 9.0,
		"surfaces": [[&"dirt", 1.0]],
		"turn": -46.0, "min_radius": 95.0, "bend_len": 300.0,
		"climb": 22.0, "max_grade": 0.10, "hills_wave": 420.0,
		"features": {
			"moguls": {"from": 0.46, "to": 0.80, "amp": 0.80, "wave": 27.0},
			"debris": {"count": 16},
		},
	},
	{
		"id": &"village", "name": "Waypoint Village",
		"seconds": 42.0, "speed": 27.0, "half_width": 8.0,
		"surfaces": [[&"asphalt", 1.0]],
		"turn": 58.0, "min_radius": 90.0, "bend_len": 240.0,
		"tech": {"from": 0.40, "to": 0.74, "min_radius": 40.0, "bend_len": 110.0},
		"climb": 10.0, "max_grade": 0.08, "hills_wave": 300.0,
		"features": {
			"pit_apron": {"at": 0.08, "length": 130.0, "side": 1.0, "width": 11.0},
			"repair": {"at": 0.12, "side": 1.0},
			"buildings": {"from": 0.34, "to": 0.94, "count": 34, "min_h": 5.0, "max_h": 13.0},
			"debris": {"count": 8},
		},
	},
	{
		"id": &"ruins", "name": "Ruins Desert",
		"seconds": 66.0, "speed": 24.0, "half_width": 23.0,
		"surfaces": [[&"sand", 1.0]],
		"turn": -52.0, "min_radius": 150.0, "bend_len": 380.0,
		"climb": -16.0, "max_grade": 0.09, "hills_wave": 300.0,
		"features": {
			# Ruined halls: the road runs under a broken roof with a colonnade down the
			# middle, splitting it into two lanes. Pick a side early; you cannot change it.
			"ruin_halls": {"count": 3, "min_len": 140.0, "max_len": 200.0, "roof_height": 9.5,
						   "column_spacing": 12.0, "roof_gap_chance": 0.3},
			# A few free-standing columns between the halls. A wandering gap keeps a line.
			"pillars": {"from": 0.08, "to": 0.94, "spacing": 80.0, "per_cluster": 2,
						"gate_width": 10.0, "radius": 1.6, "height": 9.0},
			# Toppled columns lying across the sand near the edges.
			"fallen_columns": {"count": 10},
			"debris": {"count": 14},
		},
	},
	{
		"id": &"foothill", "name": "Foothill City",
		"seconds": 45.0, "speed": 26.0, "half_width": 8.5,
		"surfaces": [[&"asphalt", 1.0]],
		"turn": 72.0, "min_radius": 75.0, "bend_len": 210.0,
		"tech": {"from": 0.46, "to": 0.78, "min_radius": 45.0, "bend_len": 130.0},
		"climb": 90.0, "max_grade": 0.16, "hills_wave": 380.0,
		"features": {
			"repair": {"at": 0.10, "side": -1.0},
			"buildings": {"from": 0.20, "to": 0.92, "count": 40, "min_h": 7.0, "max_h": 20.0},
		},
	},
	{
		"id": &"mountain", "name": "Mountain Pass",
		"seconds": 90.0, "speed": 18.0, "half_width": 6.8,
		"surfaces": [[&"dirt", 0.30], [&"snow", 0.44], [&"dirt", 0.26]],
		"turn": -104.0, "min_radius": 60.0, "bend_len": 150.0,
		"tech": {"from": 0.22, "to": 0.86, "min_radius": 42.0, "bend_len": 120.0},
		"climb": 150.0, "max_grade": 0.20, "hills_wave": 300.0,
		"features": {
			# Ice as scattered patches inside the snow, not a section of its own.
			"ice_patches": {"from": 0.26, "to": 0.88, "count": 18, "min_len": 12.0, "max_len": 30.0},
			"rocks": {"from": 0.12, "to": 0.94, "count": 26},
		},
	},
	{
		"id": &"descent", "name": "Descent & Arena",
		"seconds": 62.0, "speed": 24.0, "half_width": 9.0,
		"surfaces": [[&"snow", 0.18], [&"dirt", 0.46], [&"asphalt", 0.36]],
		"turn": 88.0, "min_radius": 85.0, "bend_len": 180.0,
		"tech": {"from": 0.05, "to": 0.42, "min_radius": 55.0, "bend_len": 140.0},
		"climb": -196.0, "max_grade": 0.22, "hills_wave": 320.0,
		"features": {
			"repair": {"at": 0.015, "side": 1.0},
			"ice_patches": {"from": 0.04, "to": 0.22, "count": 5, "min_len": 10.0, "max_len": 20.0},
			"rocks": {"from": 0.06, "to": 0.34, "count": 12},
			# The finishing straight opens out and is lined with stands.
			"arena": {"from": 0.80, "half_width": 14.0, "stands": 30},
			"debris": {"count": 10},
		},
	},
]

## Metres of run-up behind the start line, so the grid has somewhere to sit.
const START_RUN_UP := 130.0
## Metres of run-off past the finish line, so nobody drives off the end of the world.
const FINISH_RUN_OFF := 220.0
## Distance over which road width eases from one stage's value to the next.
const WIDTH_BLEND := 70.0
## One gadget box every this many metres, drifting from side to side of the road.
const PICKUP_SPACING := 480.0
