// ============================================================================
// psx.gdshader  (spatial)  —  PS1-style vertex snapping + affine textures.
// ----------------------------------------------------------------------------
// Vertex stage: snap projected NDC.xy to a grid (the retro wobble), damped by
//   snap_resolution (higher = finer = less wobble) and snap_strength (blend).
//
// Texture stage: samples albedo_tex with NEAREST filtering (pixelated texels)
//   and supports AFFINE (perspective-incorrect) UV mapping — the PS1 texture
//   "warp". Trick: pass UV*w and w as varyings; uv = (UV*w)/w under the GPU's
//   perspective interpolation cancels the perspective correction, giving screen-
//   linear (affine) UVs. affine_strength blends correct <-> affine.
//
// albedo_tex defaults to white, so materials that set no texture are unaffected;
// affine_strength defaults to 0, so they also keep correct mapping.
// ============================================================================
shader_type spatial;

uniform sampler2D albedo_tex : source_color, hint_default_white, filter_nearest;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 emission_color : source_color = vec4(0.0);
uniform float emission_energy = 0.0;
uniform float roughness_val : hint_range(0.0, 1.0) = 1.0;
uniform float snap_resolution = 90.0;
uniform float snap_strength : hint_range(0.0, 1.0) = 0.6;
uniform float affine_strength : hint_range(0.0, 1.0) = 0.0;

varying vec2 v_uv_w;
varying float v_w;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	if (clip.w > 0.0) {
		vec2 ndc = clip.xy / clip.w;
		vec2 snapped = floor(ndc * snap_resolution) / snap_resolution;
		clip.xy = mix(ndc, snapped, snap_strength) * clip.w;
	}
	POSITION = clip;

	// For affine mapping: carry UV*w and w so the fragment can cancel the
	// perspective correction the rasterizer would otherwise apply.
	v_w = max(clip.w, 0.0001);
	v_uv_w = UV * v_w;
}

void fragment() {
	vec2 uv_affine = v_uv_w / v_w;          // screen-linear (affine) UVs
	vec2 uv = mix(UV, uv_affine, affine_strength);
	vec4 tex = texture(albedo_tex, uv);
	ALBEDO = tex.rgb * albedo_color.rgb;
	ROUGHNESS = roughness_val;
	EMISSION = emission_color.rgb * emission_energy;
}
