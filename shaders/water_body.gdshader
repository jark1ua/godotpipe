// ============================================================================
// water_body.gdshader — animated water for the ocean, inland lakes and rivers.
// ----------------------------------------------------------------------------
// One shader drives all three (use_mask selects the lake clip; flow_speed>0 marks a
// river ribbon). The job here is to make a FLAT plane/ribbon read as a 3-D body of
// water from ANY angle — the previous version looked flat (2-D) at grazing angles,
// especially on the thin river ribbons. What sells real water at a glancing angle is
// not depth alone, it is a RIPPLED, REFLECTIVE surface, so this shader adds:
//
//   * Multi-octave animated ripples (big swell + fine chop), with the normal computed
//     ANALYTICALLY per fragment so the detail is independent of the coarse plane
//     tessellation — at grazing angles the surface shimmers instead of going flat.
//   * Sky reflection driven by Fresnel: near grazing the surface mirrors a sky gradient
//     (rippled by the normals), the strongest "this is a 3-D surface" cue.
//   * A sun specular glint (additive, so it shows regardless of the scene's lights).
//   * Depth fade + refraction of the bed (lakes/ocean) and shoreline foam where the
//     water column is thin — the volume cues, kept but no longer allowed to wash the
//     surface out to a flat sheet.
//
// Rivers are shallow ribbons sitting just above the terrain, so the depth cue is ~0 and
// would (and did) wash them to flat wet rock. For a river we IGNORE the measured column,
// use a fixed body depth, scroll the ripples DOWNSTREAM (UV.y) and keep it opaque — so a
// river reads as moving water, not a decal.
//
// Depth/refraction read hint_depth_texture / hint_screen_texture (spatial only) with the
// project's reverse-Z convention: sky / cleared depth == 0 (see CLAUDE.md "Shaders").
// ============================================================================
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.45, 0.55);
uniform vec3 deep_color : source_color = vec3(0.02, 0.12, 0.22);
uniform vec3 fresnel_color : source_color = vec3(0.55, 0.75, 0.85);
uniform float alpha : hint_range(0.0, 1.0) = 0.82;

// --- waves / ripples (the surface shape & detail) ---------------------------
uniform float wave_speed = 0.6;
uniform float wave_height = 0.18;   // vertical displacement of the big swell (m)
uniform float wave_freq = 0.06;     // base spatial frequency of the swell (1/m)
uniform float ripple_strength : hint_range(0.0, 3.0) = 1.4;  // normal perturbation gain
uniform float choppiness : hint_range(0.0, 3.0) = 1.0;       // weight of the fine chop

// --- reflection / lighting (the "3-D at grazing angles" cues) ---------------
uniform vec3 sky_horizon_color : source_color = vec3(0.55, 0.72, 0.86);
uniform vec3 sky_zenith_color : source_color = vec3(0.28, 0.5, 0.75);
uniform float reflection_strength : hint_range(0.0, 1.0) = 0.7;
uniform vec3 sun_direction = vec3(0.4, -0.7, 0.35);   // world dir the sun travels
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.86);
uniform float sun_shininess : hint_range(8.0, 512.0) = 180.0;
uniform float sun_strength : hint_range(0.0, 3.0) = 1.2;

// --- depth-driven volume cues (lakes/ocean) ---------------------------------
uniform float depth_fade_distance : hint_range(0.5, 60.0) = 14.0;
uniform float refraction_strength : hint_range(0.0, 0.2) = 0.03;
uniform vec3 foam_color : source_color = vec3(0.92, 0.96, 0.99);
uniform float foam_depth : hint_range(0.0, 8.0) = 1.4;
uniform float foam_strength : hint_range(0.0, 1.0) = 0.6;

// Lake shoreline clip. mask_min/mask_max are the lake bbox in world (x, z). The mask
// is a binary outline (255 = water); row 0 = south(+Z), matching the build tool.
uniform bool use_mask = false;
uniform sampler2D mask_tex : filter_linear;
uniform vec2 mask_min = vec2(0.0);
uniform vec2 mask_max = vec2(1.0);

// River flow. flow_speed>0 marks a river ribbon (UV.y runs downstream).
uniform float flow_speed = 0.0;
uniform float flow_strength : hint_range(0.0, 1.0) = 0.35;
uniform float flow_lines = 6.0;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_wpos;

// One directional wave octave: returns (height, dH/dx, dH/dz) at world-xz p.
vec3 wave_oct(vec2 p, vec2 dir, float freq, float amp, float spd, float t) {
	float ph = dot(p, dir) * freq + t * spd;
	float s = sin(ph);
	float c = cos(ph);
	return vec3(amp * s, amp * freq * c * dir.x, amp * freq * c * dir.y);
}

// Sum a few octaves of swell + chop. `fscale` multiplies every octave's frequency (rivers
// pass a larger value so ripples are small enough to vary across a narrow channel instead
// of being one flat slice of a big ocean swell). flow shifts the directions downstream.
// Returns (height, dH/dx, dH/dz).
vec3 water_waves(vec2 p, float t, vec2 flow, float fscale) {
	float f = wave_freq * fscale;
	vec3 a = vec3(0.0);
	a += wave_oct(p, normalize(vec2(1.0, 0.35) + flow), f, 1.0, 1.0, t);
	a += wave_oct(p, normalize(vec2(-0.4, 1.0) + flow), f * 1.9, 0.5, 1.3, t);
	a += wave_oct(p, normalize(vec2(0.7, -0.8) + flow * 1.5), f * 3.7,
			0.25 * choppiness, 1.7, t);
	a += wave_oct(p, normalize(vec2(-0.9, -0.3) + flow * 1.5), f * 6.1,
			0.13 * choppiness, 2.3, t);
	return a;
}

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME * wave_speed;
	float fscale = flow_speed > 0.0 ? 8.0 : 1.0;   // rivers: finer ripples
	vec2 flow = flow_speed > 0.0 ? vec2(0.0, 1.2) : vec2(0.0);
	// Plane is translation-only (axis-aligned, unit scale), so object Y == world Y.
	VERTEX.y += water_waves(v_wpos.xz, t, flow, fscale).x * wave_height;
}

void fragment() {
	if (use_mask) {
		vec2 muv = vec2(
			(v_wpos.x - mask_min.x) / max(mask_max.x - mask_min.x, 1e-3),
			(mask_max.y - v_wpos.z) / max(mask_max.y - mask_min.y, 1e-3));
		if (muv.x < 0.0 || muv.x > 1.0 || muv.y < 0.0 || muv.y > 1.0
				|| texture(mask_tex, muv).r < 0.5) {
			discard;
		}
	}

	bool is_river = flow_speed > 0.0;
	float t = TIME * wave_speed;
	float fscale = is_river ? 8.0 : 1.0;          // rivers: finer ripples (see vertex())
	vec2 flow = is_river ? vec2(0.0, 1.2) : vec2(0.0);

	// Analytic ripple normal (world space) -> view space for shading/Fresnel.
	vec3 w = water_waves(v_wpos.xz, t, flow, fscale);
	vec3 wnorm = normalize(vec3(-w.y * ripple_strength, 1.0, -w.z * ripple_strength));
	vec3 vnorm = normalize((VIEW_MATRIX * vec4(wnorm, 0.0)).xyz);
	NORMAL = vnorm;

	// Scene depth behind this fragment -> water column thickness (view space).
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw);
	vec4 vp = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_z = vp.z / vp.w;
	float has_geo = step(0.0001, raw);
	float water_depth = max(0.0, VERTEX.z - scene_z);
	water_depth = mix(depth_fade_distance * 4.0, water_depth, has_geo);
	// Rivers ignore the (≈0) measured column and use a fixed body depth so they read as
	// water, not wet rock; lakes/ocean use the real column.
	float depth_t = is_river ? 0.6 : clamp(water_depth / depth_fade_distance, 0.0, 1.0);

	// Refraction: push the underwater screen sample by the ripple normal (fade to 0 in
	// the shallows so the near-shore bed doesn't smear).
	vec2 refr_uv = SCREEN_UV + vnorm.xy * refraction_strength * clamp(depth_t * 2.0, 0.0, 1.0);
	vec3 below = texture(screen_tex, refr_uv).rgb;

	// Water body colour: shallow -> deep by column depth.
	vec3 body = mix(shallow_color, deep_color, depth_t);
	// Refracted bed shows through in the shallows, water colour dominates in the deep.
	vec3 col = mix(below * mix(vec3(1.0), shallow_color, 0.35), body,
			clamp(depth_t * 1.15, 0.0, 1.0));

	// Fresnel: more reflective toward grazing angles.
	vec3 view_w = normalize(CAMERA_POSITION_WORLD - v_wpos);
	float fres = clamp(pow(1.0 - max(dot(wnorm, view_w), 0.0), 5.0), 0.0, 1.0);
	fres = mix(0.02, 1.0, fres);   // base reflectance ~2% straight down

	// Sky reflection (rippled by the normal): pick a sky gradient from the reflected ray.
	vec3 refl = reflect(-view_w, wnorm);
	vec3 sky = mix(sky_horizon_color, sky_zenith_color, clamp(refl.y, 0.0, 1.0));
	col = mix(col, sky, fres * reflection_strength);

	// Shoreline foam where the column is thin (skip on rivers — handled by flow bands).
	float foam = (1.0 - smoothstep(0.0, foam_depth, water_depth)) * foam_strength * has_geo;
	if (is_river) { foam = 0.0; }
	col = mix(col, foam_color, foam);

	if (is_river) {
		// Bright bands scrolling downstream (UV.y) to read as current.
		float fl = sin((UV.y * flow_lines - TIME * flow_speed) * 6.2831853);
		col = mix(col, fresnel_color, clamp(fl, 0.0, 1.0) * 0.2 * flow_strength);
	}

	// Sun specular glint (additive via EMISSION so it survives regardless of scene lights
	// and reads as a sparkling 3-D surface). Blinn-Phong against the rippled normal.
	vec3 sdir = normalize(-sun_direction);
	vec3 h = normalize(sdir + view_w);
	float spec = pow(max(dot(wnorm, h), 0.0), sun_shininess);
	vec3 glint = sun_color * spec * sun_strength;

	ALBEDO = col;
	EMISSION = glint;
	METALLIC = 0.0;
	ROUGHNESS = mix(0.02, 0.1, depth_t);
	SPECULAR = 0.5;

	// Alpha: rivers stay essentially opaque; lakes/ocean fade softly to the waterline and
	// gain opacity from reflection so a grazing surface never disappears.
	if (is_river) {
		ALPHA = clamp(alpha + 0.12, 0.0, 1.0);
	} else {
		float edge = smoothstep(0.0, foam_depth * 1.5, water_depth);
		float a = mix(0.0, alpha, edge);
		a = max(a, fres * reflection_strength);   // reflective sheen keeps grazing visible
		ALPHA = max(foam, a);
	}
}
