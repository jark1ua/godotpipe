// ============================================================================
// water.gdshader  —  a simple animated water surface (spatial shader).
// ----------------------------------------------------------------------------
// Runs on the pond's MeshInstance3D. The vertex stage displaces the surface
// into rolling waves over TIME; the fragment stage blends a shallow/deep color
// with a fresnel rim and writes ALPHA < 1 so the water reads as translucent.
// This is GPU work — exactly the kind of per-vertex/per-pixel effect that would
// be absurd to attempt in C#/GDScript.
// ============================================================================
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.16, 0.45, 0.55);
uniform vec3 deep_color : source_color = vec3(0.02, 0.12, 0.22);
uniform vec3 fresnel_color : source_color = vec3(0.55, 0.75, 0.85);
uniform float wave_speed = 0.6;
uniform float wave_height = 0.12;
uniform float wave_freq = 1.8;

void vertex() {
	float t = TIME * wave_speed;
	float w = sin((VERTEX.x + t) * wave_freq) * cos((VERTEX.z - t) * wave_freq);
	w += 0.5 * sin((VERTEX.x * 2.3 - t) * wave_freq);
	VERTEX.y += w * wave_height;
}

void fragment() {
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	vec3 body = mix(deep_color, shallow_color, fres * 0.5 + 0.3);
	ALBEDO = mix(body, fresnel_color, fres);
	METALLIC = 0.2;
	ROUGHNESS = 0.08;
	ALPHA = 0.82;
}
