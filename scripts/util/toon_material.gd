class_name ToonMaterial
extends RefCounted
## Factory for the cel-shaded material used on everything in the game.

const SHADER := preload("res://shaders/toon.gdshader")


static func make(color: Color, bands: float = 3.0, shadow_floor: float = 0.45, rim: float = 0.2) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("bands", bands)
	m.set_shader_parameter("shadow_floor", shadow_floor)
	m.set_shader_parameter("rim", rim)
	return m
