// ============================================================================
// psx.gdshader  (spatial)  —  PS1-style vertex snapping, semi-stabilized.
// ----------------------------------------------------------------------------
// The retro "wobble" comes from old consoles quantizing projected vertex
// positions to a low-resolution grid (no sub-pixel precision). We reproduce it
// in the vertex stage: project to clip space, snap NDC.xy to a grid, write
// POSITION. Two knobs tame the notorious "swimming":
//
//   snap_resolution — grid cells across the screen. HIGHER = finer = less wobble.
//   snap_strength   — blends snapped vs. smooth position (0 = off, 1 = full PS1).
//                     Values < 1 keep the look while damping the jitter.
//
// The fragment stage is a normal lit surface driven by uniforms, so these
// materials still react to the scene's sun/lamps. Albedo texture + affine
// (perspective-incorrect) UV warping are intentionally left for the texture pass.
// ============================================================================
shader_type spatial;

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 emission_color : source_color = vec4(0.0);
uniform float emission_energy = 0.0;
uniform float roughness_val : hint_range(0.0, 1.0) = 1.0;
uniform float snap_resolution = 90.0;
uniform float snap_strength : hint_range(0.0, 1.0) = 0.6;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	// Guard against the clip-space w (avoid dividing behind the camera).
	if (clip.w > 0.0) {
		vec2 ndc = clip.xy / clip.w;
		vec2 snapped = floor(ndc * snap_resolution) / snap_resolution;
		clip.xy = mix(ndc, snapped, snap_strength) * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	ALBEDO = albedo_color.rgb;
	ROUGHNESS = roughness_val;
	EMISSION = emission_color.rgb * emission_energy;
}
