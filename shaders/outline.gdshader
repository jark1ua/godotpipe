// ============================================================================
// outline.gdshader  —  screen-space edge-detection outlines (post-process).
// ----------------------------------------------------------------------------
// Reads the depth and normal-roughness buffers (Forward+) of the rendered 3D
// frame and darkens pixels that sit on an edge:
//   * DEPTH discontinuity  -> silhouettes (object against background / others)
//   * NORMAL discontinuity -> interior creases (wall meets roof, etc.)
//
// A geometry mask (depth != cleared) keeps the sky from being outlined. Runs on
// a screen-covering ColorRect; reads the frame through hint_screen_texture.
// Concept adapted from lettier's "3D Game Shaders For Beginners" (Panda3D) to
// Godot's shading language.
// ============================================================================
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;

uniform vec3 outline_color : source_color = vec3(0.04, 0.04, 0.06);
uniform float thickness : hint_range(0.5, 4.0) = 1.2;
uniform float depth_edge : hint_range(0.0, 0.02) = 0.003;
uniform float normal_edge : hint_range(0.0, 2.0) = 0.7;
uniform float strength : hint_range(0.0, 1.0) = 1.0;

vec3 nrm(vec2 uv) {
	return texture(normal_tex, uv).xyz * 2.0 - 1.0;
}

void fragment() {
	vec2 px = thickness / vec2(textureSize(screen_tex, 0));
	vec2 ox = vec2(px.x, 0.0);
	vec2 oy = vec2(0.0, px.y);
	vec3 base = texture(screen_tex, SCREEN_UV).rgb;

	float d0 = texture(depth_tex, SCREEN_UV).r;
	// Reverse-Z: sky/cleared depth is 0 -> only treat written geometry as edges.
	float mask = step(0.00001, d0);

	float de = abs(d0 - texture(depth_tex, SCREEN_UV + ox).r)
			 + abs(d0 - texture(depth_tex, SCREEN_UV - ox).r)
			 + abs(d0 - texture(depth_tex, SCREEN_UV + oy).r)
			 + abs(d0 - texture(depth_tex, SCREEN_UV - oy).r);

	vec3 n0 = nrm(SCREEN_UV);
	float ne = (1.0 - dot(n0, nrm(SCREEN_UV + ox)))
			 + (1.0 - dot(n0, nrm(SCREEN_UV - ox)))
			 + (1.0 - dot(n0, nrm(SCREEN_UV + oy)))
			 + (1.0 - dot(n0, nrm(SCREEN_UV - oy)));

	float edge = max(step(depth_edge, de), step(normal_edge, ne)) * mask * strength;
	COLOR = vec4(mix(base, outline_color, edge), 1.0);
}
