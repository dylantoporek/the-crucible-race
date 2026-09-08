extends CanvasLayer
## Telemetry overlay for tuning: speed, surface, grip usage, per-wheel state, race progress.
## Built in code so it stays trivially editable. Toggle with F1 (`toggle_debug`).

var game: Node
var player: RaycastCar

var _speed_label: Label
var _surface_label: Label
var _grip_bar: ProgressBar
var _race_label: Label
var _progress_bar: ProgressBar
var _telemetry: Label
var _controls: Label


func setup(p_game: Node) -> void:
	game = p_game
	player = game.player
	_build()


func _build() -> void:
	var font_big := 44
	var font_mid := 20
	var font_small := 14

	# Bottom-right: speed + surface + grip bar.
	var speed_box := VBoxContainer.new()
	speed_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	speed_box.offset_left = -300
	speed_box.offset_top = -150
	speed_box.offset_right = -24
	speed_box.offset_bottom = -24
	speed_box.alignment = BoxContainer.ALIGNMENT_END
	add_child(speed_box)

	_surface_label = _label("", font_mid, HORIZONTAL_ALIGNMENT_RIGHT)
	speed_box.add_child(_surface_label)
	_speed_label = _label("0", font_big, HORIZONTAL_ALIGNMENT_RIGHT)
	speed_box.add_child(_speed_label)
	_grip_bar = ProgressBar.new()
	_grip_bar.min_value = 0.0
	_grip_bar.max_value = 1.0
	_grip_bar.show_percentage = false
	_grip_bar.custom_minimum_size = Vector2(276, 10)
	speed_box.add_child(_grip_bar)
	speed_box.add_child(_label("grip usage", font_small, HORIZONTAL_ALIGNMENT_RIGHT))

	# Top-left: position, stage, elapsed time and how far is left.
	var race_box := VBoxContainer.new()
	race_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	race_box.offset_left = 24
	race_box.offset_top = 20
	race_box.offset_right = 400
	add_child(race_box)
	_race_label = _label("", font_mid, HORIZONTAL_ALIGNMENT_LEFT)
	race_box.add_child(_race_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(340, 8)
	race_box.add_child(_progress_bar)

	# Left: per-wheel telemetry.
	_telemetry = _label("", font_small, HORIZONTAL_ALIGNMENT_LEFT)
	_telemetry.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	_telemetry.offset_left = 24
	_telemetry.offset_top = -80
	_telemetry.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.85))
	add_child(_telemetry)

	# Bottom-left: controls.
	_controls = _label(
		"W/S or triggers  throttle / brake (brake when stopped = reverse)\n" +
		"A/D or left stick  steer      Space or X  handbrake\n" +
		"R  reset to track      F1  toggle HUD",
		font_small, HORIZONTAL_ALIGNMENT_LEFT)
	_controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_controls.offset_left = 24
	_controls.offset_top = -80
	_controls.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.7))
	add_child(_controls)


func _label(text: String, size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 6)
	return l


func _process(_delta: float) -> void:
	if player == null:
		return
	var kmh := absf(player.speed) * 3.6
	_speed_label.text = "%d km/h" % int(round(kmh))
	if player.reversing:
		_speed_label.text = "R  " + _speed_label.text
	var s := player.current_surface
	_surface_label.text = s.display_name.to_upper() if s else ""
	_surface_label.add_theme_color_override("font_color", s.color.lightened(0.45) if s else Color.WHITE)
	_grip_bar.value = player.grip_usage()
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.3, 0.9, 0.4).lerp(Color(0.95, 0.25, 0.2), clampf(_grip_bar.value, 0.0, 1.0))
	_grip_bar.add_theme_stylebox_override("fill", fill)

	var stage: Dictionary = game.track.stage_at(game.track.track_offset(player))
	var remaining: float = game.distance_remaining(player)
	if game.player_finished:
		_race_label.text = "FINISHED  P%d / %d     %s     HITS %d\n%s" % [
			game.player_finish_place, game.cars.size(), _fmt_time(game.player_finish_time),
			player.hits, stage.get("name", "")]
	else:
		_race_label.text = "P%d / %d     %s     HITS %d\n%s     %.0f m to go" % [
			game.position_of(player), game.cars.size(), _fmt_time(game.race_time),
			player.hits, stage.get("name", ""), remaining]
	_progress_bar.value = game.progress_of(player)

	var lines := PackedStringArray()
	lines.append("FPS %d   grounded %d/4   steer %+.2f" % [Engine.get_frames_per_second(), player.grounded_wheels, player.steer])
	for w in player.wheels:
		var name := w.name.trim_prefix("Wheel")
		if w.grounded:
			lines.append("%s  %-7s load %5.0f  comp %.2f  lat %+5.1f  use %.2f %s" % [
				name, w.surface.display_name if w.surface else "-", w.load, w.compression,
				w.slip_lateral, w.slip_ratio, "SLIP" if w.slipping else ""])
		else:
			lines.append("%s  airborne" % name)
	_telemetry.text = "\n".join(lines)


func _fmt_time(t: float) -> String:
	var minutes := int(t / 60.0)
	var seconds := t - minutes * 60.0
	return "%d:%06.3f" % [minutes, seconds]
