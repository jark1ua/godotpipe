// ============================================================================
// grass_wind.gdshader  —  animated, two-sided grass for MultiMesh instancing.
// ----------------------------------------------------------------------------
// Designed for thousands of grass blades drawn through a single MultiMesh (see
// terrain/GrassScatterer.gd). Each instance's transform supplies its world
// position; this shader bends every blade in the wind, anchored at the base.
//
// Look: cartoon/stylised on purpose — a base->tip colour gradient (so it reads
// even with a flat, untextured blade mesh), with an OPTIONAL albedo texture for
// grass cards. Set `texture_mix` to 1.0 and feed an alpha-cut card texture, or
// leave it 0.0 for the pure-gradient stylised look.
//
// AUTHORING CONTRACT for the grass mesh you plug in (you are making it elsewhere):
//   * Pivot at the BASE of the blade: VERTEX.y = 0 at the ground, growing up to
//     ~`blade_height`. The wind mask uses VERTEX.y so the roots stay planted.
//   * UV.y from 0 (base) to 1 (tip) if you use a card texture.
//   * Two-sided is handled here (cull_disabled + back-face normal flip), so a
//     single-sided card is fine.
//   * Mesh LODs (which you bake on import) are applied by the MultiMesh
//     automatically — nothing to do in the shader.
// ============================================================================
shader_type spatial;
// cull_disabled => 2-sided cards. ALPHA_SCISSOR (set in fragment) keeps grass in
// the OPAQUE pass: it casts/receives shadows and needs no transparency sorting.
// depth_prepass_alpha cleans up the cut edges.
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley;

// ---- look (stylised gradient; texture optional) ----------------------------
uniform vec3 base_color : source_color = vec3(0.10, 0.28, 0.08);
uniform vec3 tip_color  : source_color = vec3(0.42, 0.68, 0.22);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap;
uniform float texture_mix : hint_range(0.0, 1.0) = 0.0;   // 0 = gradient only, 1 = use texture
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5; // cut threshold for card alpha
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;
uniform float ground_ao : hint_range(0.0, 1.0) = 0.55;    // darken the base for fake contact AO

// ---- shape / bend ----------------------------------------------------------
uniform float blade_height = 1.0;                  // metres base->tip; scales the sway mask
uniform float bend_exponent : hint_range(0.5, 4.0) = 1.6; // >1 = stiffer near the base

// ---- wind ------------------------------------------------------------------
uniform vec2 wind_dir = vec2(1.0, 0.35);                    // world XZ direction (un-normalised ok)
uniform float wind_strength : hint_range(0.0, 1.0) = 0.18;  // tip sway in metres
uniform float wind_speed = 1.2;
uniform float wind_scale = 0.15;                            // spatial frequency of the gust wave
uniform float flutter_strength : hint_range(0.0, 0.5) = 0.05;
uniform float flutter_speed = 4.0;

varying float v_h;   // normalised height up the blade (0 base .. 1 tip)

void vertex() {
	float h = clamp(VERTEX.y / max(blade_height, 0.001), 0.0, 1.0);
	v_h = h;
	float mask = pow(h, bend_exponent);   // 0 at the root, ~1 at the tip

	// Per-instance world origin drives the gust phase so neighbouring clumps are
	// spatially coherent (a wave rolls across the field) instead of in lockstep.
	vec3 inst_world = MODEL_MATRIX[3].xyz;
	vec2 wd = normalize(wind_dir + vec2(1e-4, 0.0));
	float phase = dot(inst_world.xz, wd) * wind_scale + TIME * wind_speed;
	float sway = sin(phase) + 0.3 * sin(phase * 2.3 + 1.7);
	float flutter = sin(TIME * flutter_speed + inst_world.x * 1.7 + inst_world.z * 2.1) * flutter_strength;

	// Bend toward the world wind direction. Rotate that world vector into THIS
	// instance's object space so the whole field leans the same way regardless of
	// each blade's random yaw. For a rotation (+uniform scale) basis the transpose
	// is the inverse, and `worldVec * mat3(MODEL)` == `transpose(mat3) * worldVec`,
	// so we get the object-space direction without a costly inverse(). (Non-uniform
	// scale would mis-scale the amplitude a touch — grass uses uniform scale.)
	vec3 bend_world = vec3(wd.x, 0.0, wd.y) * (sway * wind_strength + flutter);
	vec3 bend_obj = bend_world * mat3(MODEL_MATRIX);
	VERTEX.xz += bend_obj.xz * mask;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	vec3 grad = mix(base_color, tip_color, v_h);
	// texture_mix 0 -> pure gradient; 1 -> texture tinted by the gradient.
	ALBEDO = mix(grad, tex.rgb * grad, texture_mix);
	ALBEDO *= mix(ground_ao, 1.0, v_h);   // fake contact AO at the base
	ALPHA = mix(1.0, tex.a, texture_mix);
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
	ROUGHNESS = roughness_val;
	METALLIC = 0.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;   // light the back faces correctly
}
