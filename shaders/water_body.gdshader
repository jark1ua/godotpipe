// ============================================================================
// water_body.gdshader — animated water for the ocean and inland lakes.
// ----------------------------------------------------------------------------
// One shader drives both:
//   * Ocean  — a single plane at sea level that follows the player. use_mask=false,
//     so it covers everything; land (opaque, above sea level) simply draws in front,
//     giving exact coastlines for free.
//   * Lakes  — a plane sized to a lake's bounding box at the lake's water level.
//     use_mask=true clips the plane to the lake's real shoreline via a binary outline
//     mask (terrain/water_masks/lake_*.png) sampled by WORLD position, so the water
//     never spills over the surrounding land inside the bbox.
//
// Why it does NOT look like a flat sheet of paper:
//   The "2D / no depth" look comes from a flat translucent plane with one solid colour.
//   Real water reads as a volume because of three depth-driven cues, all added here and
//   all done in the SHADER (no fluid sim / physics needed):
//     1. Depth fade   — sample the scene DEPTH behind the surface and darken/teal the
//        colour as the water column gets deeper (shallow rim is light, middle is deep).
//     2. Refraction   — offset the SCREEN sample under the surface by the ripple normal
//        so the lake/sea bed wobbles, selling that you're looking THROUGH water.
//     3. Shoreline foam — a bright band where the water column is very thin (where the
//        bed rises to meet the surface), i.e. an automatic waterline of foam.
//   Plus a Fresnel rim and per-fragment ripple normals (analytic, independent of the
//   coarse plane tessellation) so the surface catches specular highlights at a glance.
//
// Waves are computed from WORLD xz (not the mesh), so the ocean's wave pattern stays
// put in the world as its plane is recentred on the player every frame — no crawling.
//
// Depth/refraction read hint_depth_texture / hint_screen_texture, which only exist in
// SPATIAL shaders (this is one). Godot uses reverse-Z: the sky / cleared depth is 0, so
// we guard the reconstruction with that (see CLAUDE.md "Shaders").
// ============================================================================
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.45, 0.55);
uniform vec3 deep_color : source_color = vec3(0.02, 0.12, 0.22);
uniform vec3 fresnel_color : source_color = vec3(0.55, 0.75, 0.85);
uniform float alpha : hint_range(0.0, 1.0) = 0.82;
uniform float wave_speed = 0.6;
uniform float wave_height = 0.12;
uniform float wave_freq = 0.25;   // lower than the pond shader: these planes are huge

// --- depth-driven volume cues (the "make it look 3D" part) ------------------
// Metres of water column over which the colour ramps shallow -> deep. Past this depth
// the water reads as full deep_color and is most opaque.
uniform float depth_fade_distance : hint_range(0.5, 60.0) = 14.0;
// Refraction: how far (screen fraction) the underwater view is pushed by the ripples.
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.035;
// Foam: water columns thinner than foam_depth get a foam band (the waterline).
uniform vec3 foam_color : source_color = vec3(0.9, 0.95, 0.98);
uniform float foam_depth : hint_range(0.0, 8.0) = 1.6;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.7;
// Ripple normal detail strength (analytic, from the wave function derivatives).
uniform float ripple_strength : hint_range(0.0, 2.0) = 0.8;

// Lake shoreline clip. mask_min/mask_max are the lake bbox in world (x, z). The mask
// is a binary outline (255 = water); row 0 = south(+Z), matching the build tool.
uniform bool use_mask = false;
uniform sampler2D mask_tex : filter_linear;
uniform vec2 mask_min = vec2(0.0);
uniform vec2 mask_max = vec2(1.0);

// River flow. On river ribbons (UV.y runs down the channel) flow_speed > 0 scrolls a
// soft highlight along the length to read as moving water. 0 on lakes/ocean (no-op).
uniform float flow_speed = 0.0;
uniform float flow_strength : hint_range(0.0, 1.0) = 0.35;
uniform float flow_lines = 6.0;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_wpos;

// Wave height at a world xz (shared by vertex displacement and the analytic normal).
float wave_h(vec2 p, float t) {
	float w = sin((p.x + t) * wave_freq) * cos((p.y - t) * wave_freq);
	w += 0.5 * sin((p.x * 2.3 - t) * wave_freq);
	return w;
}

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wave_speed;
	// Plane is translation-only (axis-aligned, unit scale), so object Y == world Y.
	VERTEX.y += wave_h(v_wpos.xz, t) * wave_height;
}

void fragment() {
	if (use_mask) {
		vec2 muv = vec2(
			(v_wpos.x - mask_min.x) / max(mask_max.x - mask_min.x, 1e-3),
			(mask_max.y - v_wpos.z) / max(mask_max.y - mask_min.y, 1e-3));
		// Outside the bbox or off the masked shoreline -> no water here.
		if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0
				|| texture(mask_tex, muv).r < 0.5) {
			discard;
		}
	}

	// Per-fragment ripple normal from the analytic wave derivatives (so detail does not
	// depend on the plane's coarse tessellation). World space, then into view space.
	float t = TIME * wave_speed;
	vec2 wp = v_wpos.xz;
	float e = 0.75;
	float dx = (wave_h(wp + vec2(e, 0.0), t) - wave_h(wp - vec2(e, 0.0), t)) / (2.0 * e);
	float dz = (wave_h(wp + vec2(0.0, e), t) - wave_h(wp - vec2(0.0, e), t)) / (2.0 * e);
	vec3 wnorm = normalize(vec3(-dx * wave_height * ripple_strength, 1.0,
								-dz * wave_height * ripple_strength));
	vec3 vnorm = normalize((VIEW_MATRIX * vec4(wnorm, 0.0)).xyz);
	NORMAL = vnorm;

	// Scene depth behind this fragment -> thickness of the water column (view space).
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_z = vp.z / vp.w;                 // view z of the bed (negative)
	float has_geo = step(0.0001, raw);           // reverse-Z: 0 == sky / cleared
	float water_depth = max(0.0, VERTEX.z - scene_z);
	water_depth = mix(depth_fade_distance * 4.0, water_depth, has_geo);
	float depth_t = clamp(water_depth / depth_fade_distance, 0.0, 1.0);

	// Refraction: push the underwater screen sample by the ripple normal, but pull the
	// offset to zero in the shallows so the bed near the waterline doesn't smear.
	vec2 refr_uv = SCREEN_UV + vnorm.xy * refraction_strength * clamp(depth_t * 2.0, 0.0, 1.0);
	vec3 below = texture(screen_tex, refr_uv).rgb;

	// Body colour: shallow -> deep by column depth, with a Fresnel rim toward the sky.
	vec3 body = mix(shallow_color, deep_color, depth_t);
	float fres = pow(1.0 - clamp(dot(NORMAL, normalize(VIEW)), 0.0, 1.0), 3.0);
	body = mix(body, fresnel_color, fres * 0.6);

	// Blend the refracted bed through the water: clear in the shallows, opaque in the
	// deep. Tint the transmitted bed by the water colour so it doesn't look like glass.
	vec3 col = mix(below * mix(vec3(1.0), shallow_color, 0.35), body, clamp(depth_t * 1.1, 0.0, 1.0));

	// Shoreline foam where the column is thin (bed rising to meet the surface).
	float foam = (1.0 - smoothstep(0.0, foam_depth, water_depth)) * foam_strength * has_geo;
	col = mix(col, foam_color, foam);

	if (flow_speed > 0.0) {
		// Soft bright bands scrolling down the channel (UV.y) to suggest current.
		float fl = sin((UV.y * flow_lines - TIME * flow_speed) * 6.2831853);
		col = mix(col, fresnel_color, clamp(fl, 0.0, 1.0) * 0.18 * flow_strength);
	}

	ALBEDO = col;
	METALLIC = 0.0;
	ROUGHNESS = mix(0.02, 0.12, depth_t);
	SPECULAR = 0.6;
	// Fade the edge to nothing in the shallows so the waterline is soft, and keep the
	// foam visible there; deep water uses the full body alpha.
	float edge = smoothstep(0.0, foam_depth * 1.5, water_depth);
	ALPHA = max(foam, mix(0.0, alpha, edge) + fres * (1.0 - edge) * alpha);
}
