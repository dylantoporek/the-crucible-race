class_name Gadgets
extends RefCounted
## The gadget roster. A car keeps whichever gadget it last picked up and can use it again
## and again, with COOLDOWN seconds between uses. Effects live in GadgetSlot.

const COOLDOWN := 20.0

const DEFS := {
	&"jump": {
		"name": "Jump", "color": Color(0.35, 0.80, 1.00), "duration": 0.0,
		"blurb": "Launches the car over whatever is in front of it.",
	},
	&"shield": {
		"name": "Shield", "color": Color(0.55, 0.95, 0.55), "duration": 5.0,
		"blurb": "No damage for a few seconds, and anyone who touches you gets thrown.",
	},
	&"boost": {
		"name": "Boost", "color": Color(1.00, 0.60, 0.20), "duration": 3.0,
		"blurb": "A hard shove of extra power and top speed.",
	},
	&"oil": {
		"name": "Oil Slick", "color": Color(0.85, 0.45, 0.95), "duration": 0.0,
		"blurb": "Drops a slick behind you that drives like ice for a while.",
	},
}


static func ids() -> Array:
	return DEFS.keys()


static func any_id() -> StringName:
	var keys := DEFS.keys()
	return keys[randi_range(0, keys.size() - 1)]


static func random_id(rng: RandomNumberGenerator) -> StringName:
	var keys := DEFS.keys()
	return keys[rng.randi_range(0, keys.size() - 1)]


static func display_name(id: StringName) -> String:
	return DEFS.get(id, {}).get("name", "")


static func color_of(id: StringName) -> Color:
	return DEFS.get(id, {}).get("color", Color.WHITE)


static func duration_of(id: StringName) -> float:
	return float(DEFS.get(id, {}).get("duration", 0.0))
