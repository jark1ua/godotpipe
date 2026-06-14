// ============================================================================
// retro.gdshader  —  a "retro console" full-screen post-process.
// ----------------------------------------------------------------------------
// Deliberately separate from crt.gdshader: no scanlines/curvature/vignette.
// Just the three low-fi pillars, in this order:
//   1. PIXELATE   — snap screen UVs to a coarse grid (chunky pixels).
//   2. DITHER     — add an ordered (Bayer 4x4) threshold per pixel so the
//                   posterize step stipples gradients instead of hard-banding.
//   3. POSTERIZE  — quantize each channel to `color_levels` steps.
//
// Runs on a screen-covering ColorRect; reads the rendered frame through
// hint_screen_texture. All GPU, per-pixel — set the uniforms from script/Inspector.
// (This is the screen-space half; matching pixelated *textures* on the 3D models
//  themselves come later as a spatial shader / import setting.)
// ============================================================================
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;
uniform float pixel_size : hint_range(1.0, 12.0) = 4.0;   // bigger = chunkier
uniform int color_levels : hint_range(2, 64) = 8;         // posterize steps/channel
uniform float dither_strength : hint_range(0.0, 1.0) = 1.0;

// 4x4 ordered (Bayer) dither threshold for an integer pixel, centered on 0.
float bayer4(vec2 p) {
	int x = int(p.x) % 4;
	int y = int(p.y) % 4;
	int i = x + y * 4;
	float m[16] = float[16](
		0.0, 8.0, 2.0, 10.0,
		12.0, 4.0, 14.0, 6.0,
		3.0, 11.0, 1.0, 9.0,
		15.0, 7.0, 13.0, 5.0
	);
	return m[i] / 16.0 - 0.5;
}

void fragment() {
	vec2 res = vec2(textureSize(screen_tex, 0));

	// 1. pixelate: sample on a coarse grid so blocks of output share one texel.
	vec2 grid = res / max(pixel_size, 1.0);
	vec2 pix = floor(SCREEN_UV * grid);
	vec3 col = texture(screen_tex, pix / grid).rgb;

	// 2 + 3. dither, then posterize to a few levels per channel.
	float levels = float(color_levels);
	col += vec3(bayer4(pix)) * dither_strength / levels;
	col = floor(col * levels) / levels;

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
