// ============================================================================
// cobble_tess.gdshader — tessellated, displaced cobblestone ground.
//
// Real geometry displacement (not parallax fakery): the mesh must be a heavily
// subdivided PlaneMesh so there are enough vertices to push around. In vertex()
// each vertex is pushed along its normal by the height map; in fragment() the
// surface is shaded with the albedo, normal and AO maps. Together this uses all
// four cobble_*.png maps the user baked in Blender.
//
// Sampler color-space is handled here, so the maps work regardless of their
// import "color" toggle:
//   - albedo : source_color  -> sRGB decoded to linear for lighting
//   - normal : hint_normal    -> read as a tangent-space normal (no sRGB)
//   - ao/height : plain        -> read raw/linear (no sRGB)
// ============================================================================
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D height_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

// How many times the texture tiles across the mesh's 0..1 UV range.
uniform vec2 uv_scale = vec2(8.0, 8.0);
// Object-space displacement applied to (height - height_mid). Negative heights
// carve in, positive heights bulge out, so the surface straddles the plane.
uniform float height_scale : hint_range(0.0, 2.0) = 0.4;
uniform float height_mid : hint_range(0.0, 1.0) = 0.5;
// Detail strength of the tangent-space normal map.
uniform float normal_strength : hint_range(0.0, 4.0) = 1.0;
// Recompute the geometric (macro) normal from the displaced height field so the
// large bumps catch light correctly; the normal map then adds fine detail.
uniform float macro_normal_strength : hint_range(0.0, 4.0) = 1.0;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.9;
uniform float ao_light_affect : hint_range(0.0, 1.0) = 0.6;

varying vec2 tiled_uv;

// Sample the displacement (object-space Y offset) for a given tiled UV.
float sample_height(vec2 uv) {
	return (textureLod(height_tex, uv, 0.0).r - height_mid) * height_scale;
}

void vertex() {
	tiled_uv = UV * uv_scale;

	// Displace along the (flat plane) normal.
	VERTEX += NORMAL * sample_height(tiled_uv);

	// Rebuild the macro normal from the height gradient so the large displaced
	// bumps catch light (the normal map then adds fine detail on top). One-texel
	// central differences in tiled-UV space; TANGENT spans +U, BINORMAL spans +V.
	// macro_normal_strength is a tunable gain rather than a physical slope, which
	// keeps this independent of the mesh's size/scale.
	vec2 texel = 1.0 / vec2(textureSize(height_tex, 0));
	float du = sample_height(tiled_uv + vec2(texel.x, 0.0))
		- sample_height(tiled_uv - vec2(texel.x, 0.0));
	float dv = sample_height(tiled_uv + vec2(0.0, texel.y))
		- sample_height(tiled_uv - vec2(0.0, texel.y));
	NORMAL = normalize(NORMAL
		- TANGENT * du * macro_normal_strength
		- BINORMAL * dv * macro_normal_strength);
}

void fragment() {
	ALBEDO = texture(albedo_tex, tiled_uv).rgb;

	NORMAL_MAP = texture(normal_tex, tiled_uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;

	AO = texture(ao_tex, tiled_uv).r;
	AO_LIGHT_AFFECT = ao_light_affect;

	ROUGHNESS = roughness_val;
	METALLIC = 0.0;
}
