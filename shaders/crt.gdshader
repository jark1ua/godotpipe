// ============================================================================
// crt.gdshader  —  full-screen CRT / low-fidelity post-process.
// ----------------------------------------------------------------------------
// This is a `canvas_item` shader meant to run on a screen-covering ColorRect on
// a top CanvasLayer (see world.tscn -> PostProcess/CRT). It reads the already-
// rendered frame via `hint_screen_texture` and rewrites every pixel: barrel
// curvature, pixelation, chromatic aberration, color quantization, scanlines,
// animated noise, and a vignette. All of this is per-pixel work the GPU does in
// parallel; the only job left to C#/GDScript is setting the uniforms below.
//
// Every parameter is a `uniform` with hint ranges so it can be tuned live from
// the Inspector or from a script via `material.set_shader_parameter(name, val)`.
// ============================================================================
shader_type canvas_item;

// The frame as rendered so far. filter_nearest keeps the look crisp/blocky.
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;

uniform float curvature : hint_range(0.0, 0.5) = 0.08;        // barrel distortion
uniform float pixelation : hint_range(1.0, 8.0) = 2.0;        // downsample factor (low-fi)
uniform float aberration : hint_range(0.0, 4.0) = 1.2;        // chromatic split, in pixels
uniform int   color_levels : hint_range(2, 64) = 24;          // color depth (banding)
uniform float scan_intensity : hint_range(0.0, 1.0) = 0.22;   // line darkening
uniform float scan_count : hint_range(64.0, 2000.0) = 900.0;  // line density
uniform float scan_angle : hint_range(-1.6, 1.6) = 0.785;     // line angle (rad); ~0.785 = 45 deg diagonal
uniform float noise_amount : hint_range(0.0, 0.2) = 0.04;     // animated grain
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.45;
uniform float vignette_softness : hint_range(0.0, 1.0) = 0.35;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 res = vec2(textureSize(screen_tex, 0));

	// --- barrel curvature: push pixels outward from center by distance^2 ---
	vec2 cc = SCREEN_UV - 0.5;
	float d2 = dot(cc, cc);
	vec2 uv = SCREEN_UV + cc * d2 * curvature;

	// Anything bent past the screen edge becomes the black bezel. Godot's shader
	// language disallows `return` inside fragment(), so flag it and apply at the
	// end rather than bailing out early.
	bool offscreen = uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0;
	uv = clamp(uv, vec2(0.0), vec2(1.0));

	// --- pixelation: snap uv to a coarser grid for the low-fidelity look ---
	vec2 grid = res / max(pixelation, 1.0);
	uv = floor(uv * grid) / grid;

	// --- chromatic aberration: sample R/G/B at slightly offset positions ---
	vec2 px = vec2(aberration) / res;
	vec3 col;
	col.r = texture(screen_tex, uv + px).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - px).b;

	// --- color quantization: collapse to a small number of levels (banding) ---
	float levels = float(color_levels);
	col = floor(col * levels) / levels;

	// --- diagonal line grain: project uv onto an angled axis so the dark bands
	//     run at scan_angle (default ~45 deg), matching the woven look of the
	//     reference art. Aspect-correct the coordinate so lines stay straight. ---
	vec2 dir = vec2(cos(scan_angle), sin(scan_angle));
	float aspect = res.x / res.y;
	float coord = dot(SCREEN_UV * vec2(aspect, 1.0), dir);
	float s = 0.5 + 0.5 * sin(coord * scan_count * 3.14159265);
	col *= 1.0 - scan_intensity * s;

	// --- animated grain ---
	col += (rand(SCREEN_UV + vec2(TIME)) - 0.5) * noise_amount;

	// --- vignette: darken toward the corners ---
	float vig = 1.0 - vignette_strength * smoothstep(vignette_softness, 0.9, length(cc) * 1.414);
	col *= vig;

	COLOR = vec4(offscreen ? vec3(0.0) : col, 1.0);
}
