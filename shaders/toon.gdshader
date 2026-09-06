// Cel shader for the Compatibility renderer (web friendly).
// Quantises diffuse lighting into bands and adds a soft rim so shapes read at speed.
shader_type spatial;
render_mode specular_disabled, cull_disabled;

uniform vec4 albedo : source_color = vec4(0.8, 0.8, 0.8, 1.0);
uniform float bands : hint_range(1.0, 8.0, 1.0) = 3.0;
uniform float shadow_floor : hint_range(0.0, 1.0) = 0.45;
uniform float rim : hint_range(0.0, 1.0) = 0.2;

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float lit = ndl * ATTENUATION;
	float stepped = floor(lit * bands + 0.5) / bands;
	float shade = mix(shadow_floor, 1.0, stepped);
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	DIFFUSE_LIGHT += (shade + fresnel * rim * stepped) * LIGHT_COLOR / PI;
}
