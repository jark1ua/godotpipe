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
// Waves are computed from WORLD xz (not the mesh), so the ocean's wave pattern stays
// put in the world as its plane is recentred on the player every frame — no crawling.
// (Built on shaders/water.gdshader; adds world-space waves + the lake mask clip.)
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

varying vec3 v_wpos;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wave_speed;
	float w = sin((v_wpos.x + t) * wave_freq) * cos((v_wpos.z - t) * wave_freq);
	w += 0.5 * sin((v_wpos.x * 2.3 - t) * wave_freq);
	// Plane is translation-only (axis-aligned, unit scale), so object Y == world Y.
	VERTEX.y += w * wave_height;
}

void fragment() {
	if (use_mask) {
		vec2 uv = vec2(
			(v_wpos.x - mask_min.x) / max(mask_max.x - mask_min.x, 1e-3),
			(mask_max.y - v_wpos.z) / max(mask_max.y - mask_min.y, 1e-3));
		// Outside the bbox or off the masked shoreline -> no water here.
		if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0
				|| texture(mask_tex, uv).r < 0.5) {
			discard;
		}
	}
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec3 body = mix(deep_color, shallow_color, fres * 0.5 + 0.3);
	ALBEDO = mix(body, fresnel_color, fres);
	if (flow_speed > 0.0) {
		// Soft bright bands scrolling down the channel (UV.y) to suggest current.
		float fl = sin((UV.y * flow_lines - TIME * flow_speed) * 6.2831853);
		ALBEDO = mix(ALBEDO, fresnel_color, clamp(fl, 0.0, 1.0) * 0.18 * flow_strength);
	}
	METALLIC = 0.2;
	ROUGHNESS = 0.08;
	ALPHA = alpha;
}
