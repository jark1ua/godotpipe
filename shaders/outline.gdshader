// ============================================================================
// outline.gdshader  (spatial)  —  screen-space edge-detection outlines.
// ----------------------------------------------------------------------------
// Depth/normal buffers are only readable from SPATIAL shaders in Godot, so this
// is a fullscreen quad (a QuadMesh of size 2 on a MeshInstance3D child of the
// camera). The vertex stage stretches it across clip space; the fragment stage
// darkens pixels on an edge:
//   * DEPTH discontinuity  -> silhouettes
//   * NORMAL discontinuity -> interior creases
// Depth is linearized to view space (via INV_PROJECTION_MATRIX) so the threshold
// is in world units. A geometry mask (depth != cleared) keeps the sky clean.
// Drawn in the transparent pass (ALPHA written) so the screen copy already holds
// the full opaque scene. Concept adapted from lettier's shader tutorial.
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;

uniform vec3 outline_color : source_color = vec3(0.04, 0.04, 0.06);
uniform float thickness : hint_range(0.5, 4.0) = 1.2;
uniform float depth_edge : hint_range(0.0, 2.0) = 0.25;   // view-space units
uniform float normal_edge : hint_range(0.0, 2.0) = 0.7;
uniform float strength : hint_range(0.0, 1.0) = 1.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0); // fullscreen (QuadMesh size 2)
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -(v.z / v.w);
}

vec3 nrm(vec2 uv) {
	return texture(normal_tex, uv).xyz * 2.0 - 1.0;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 px = thickness / VIEWPORT_SIZE;
	vec2 ox = vec2(px.x, 0.0);
	vec2 oy = vec2(0.0, px.y);
	vec3 base = texture(screen_tex, uv).rgb;

	// Reverse-Z: sky/cleared depth is 0 -> only outline written geometry.
	float mask = step(0.00001, texture(depth_tex, uv).r);

	float d0 = linear_depth(uv, INV_PROJECTION_MATRIX);
	float de = abs(d0 - linear_depth(uv + ox, INV_PROJECTION_MATRIX))
			 + abs(d0 - linear_depth(uv - ox, INV_PROJECTION_MATRIX))
			 + abs(d0 - linear_depth(uv + oy, INV_PROJECTION_MATRIX))
			 + abs(d0 - linear_depth(uv - oy, INV_PROJECTION_MATRIX));

	vec3 n0 = nrm(uv);
	float ne = (1.0 - dot(n0, nrm(uv + ox))) + (1.0 - dot(n0, nrm(uv - ox)))
			 + (1.0 - dot(n0, nrm(uv + oy))) + (1.0 - dot(n0, nrm(uv - oy)));

	float edge = max(step(depth_edge, de), step(normal_edge, ne)) * mask * strength;
	ALBEDO = mix(base, outline_color, edge);
	ALPHA = 1.0;
}
