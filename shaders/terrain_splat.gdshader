shader_type spatial;
// ============================================================================
// Terrain control-map shader (32 layers, Texture2DArray, height blend + triplanar)
// ----------------------------------------------------------------------------
// Replaces the old 4-channel RGBA splatmap. A 16-bit single-channel control map
// packs, per texel, which two of 32 layers meet there and how they blend:
//     V          = round(control_map.r * 65535.0)
//     base_layer = V & 31
//     overlay    = (V >> 5) & 31
//     blend      = ((V >> 10) & 31) / 31.0 * 0.5     // overlay fraction, 0..0.5
// Layers live in Texture2DArrays (one slice per layer index), built at runtime by
// TerrainStreamer.gd: albedo (sRGB), normal (OpenGL Y+), ao, rough, height (linear).
//
// Detail tiling uses world XZ / per-layer tile size, so it is seamless across
// chunk borders. Height-aware blending hides layer seams; steep layers (cliff/
// scree/rock, flagged in layer_triplanar[]) use triplanar to avoid stretching.
//
// IMPORTANT: control_map MUST be sampled with NEAREST filtering and full 16-bit
// precision (no sRGB, no mipmaps) — linear filtering would interpolate packed
// integers into garbage. The streamer builds it as an R-float texture for this.
// ============================================================================

uniform sampler2D control_map : filter_nearest;
uniform sampler2DArray albedo_array : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2DArray normal_array : filter_linear_mipmap_anisotropic;
uniform sampler2DArray ao_array     : filter_linear_mipmap;
uniform sampler2DArray rough_array  : filter_linear_mipmap;
uniform sampler2DArray height_array : filter_linear_mipmap;

uniform float world_size_m = 6000.0;
uniform float default_tile_m = 12.0;
uniform float layer_tile_m[32];      // metres per tile, per layer (0 -> default_tile_m)
uniform float layer_triplanar[32];   // 1.0 -> eligible for triplanar on steep faces

uniform float height_blend_influence : hint_range(0.0, 1.0) = 0.4;
uniform float height_blend_sharpness : hint_range(0.1, 8.0) = 3.0;

uniform bool enable_triplanar = true;
uniform float triplanar_slope_start : hint_range(0.0, 1.0) = 0.35; // slope (1 - N.y)
uniform float triplanar_slope_full  : hint_range(0.0, 1.0) = 0.75;
uniform float triplanar_sharpness   : hint_range(1.0, 16.0) = 4.0;
uniform float normal_strength       : hint_range(0.0, 2.0) = 1.0;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Sample one layer's maps at this fragment. Albedo + normal get triplanar on
// steep eligible layers; ao/rough/height stay planar (cheaper, barely visible).
void sample_layer(int layer, float tri_amt, vec3 tri_w,
		out vec3 albedo, out vec3 nrm, out float ao, out float rough, out float height) {
	float tile = layer_tile_m[layer] > 0.0 ? layer_tile_m[layer] : default_tile_m;
	vec2 puv = v_world_pos.xz / tile;
	float fl = float(layer);

	albedo = texture(albedo_array, vec3(puv, fl)).rgb;
	nrm    = texture(normal_array, vec3(puv, fl)).rgb;
	ao     = texture(ao_array,     vec3(puv, fl)).r;
	rough  = texture(rough_array,  vec3(puv, fl)).r;
	height = texture(height_array, vec3(puv, fl)).r;

	float t = tri_amt * layer_triplanar[layer];
	if (t > 0.001) {
		vec2 uvx = v_world_pos.zy / tile;
		vec2 uvz = v_world_pos.xy / tile;
		vec3 a = texture(albedo_array, vec3(uvx, fl)).rgb * tri_w.x
			   + albedo * tri_w.y
			   + texture(albedo_array, vec3(uvz, fl)).rgb * tri_w.z;
		vec3 n = texture(normal_array, vec3(uvx, fl)).rgb * tri_w.x
			   + nrm * tri_w.y
			   + texture(normal_array, vec3(uvz, fl)).rgb * tri_w.z;
		albedo = mix(albedo, a, t);
		nrm = mix(nrm, n, t);
	}
}

// Height-aware overlay weight given linear blend t (0..1) and the two detail heights.
float height_blend_weight(float base_h, float over_h, float t) {
	float b1 = (1.0 - t) + base_h * height_blend_sharpness;
	float b2 = t + over_h * height_blend_sharpness;
	float m = max(b1, b2) - 0.5;       // 0.5 = transition window
	float w1 = max(b1 - m, 0.0);
	float w2 = max(b2 - m, 0.0);
	return w2 / max(w1 + w2, 1e-5);
}

void fragment() {
	// Unpack the control map at the world UV (0..1 across the whole terrain).
	uint packed = uint(texture(control_map, UV).r * 65535.0 + 0.5);
	int base_l = int(packed & 31u);
	int over_l = int((packed >> 5u) & 31u);
	float blend = (float((packed >> 10u) & 31u) / 31.0) * 0.5;

	// Triplanar context from the world-space surface normal.
	vec3 wn = normalize(v_world_normal);
	float slope = 1.0 - clamp(wn.y, 0.0, 1.0);
	float tri_amt = enable_triplanar ? smoothstep(triplanar_slope_start, triplanar_slope_full, slope) : 0.0;
	vec3 tri_w = pow(abs(wn), vec3(triplanar_sharpness));
	tri_w /= max(tri_w.x + tri_w.y + tri_w.z, 1e-5);

	vec3 ba, bn; float bao, brough, bh;
	vec3 oa, on; float oao, orough, oh;
	sample_layer(base_l, tri_amt, tri_w, ba, bn, bao, brough, bh);
	sample_layer(over_l, tri_amt, tri_w, oa, on, oao, orough, oh);

	float hbw = height_blend_weight(bh, oh, blend);
	float final_blend = mix(blend, hbw, height_blend_influence);

	vec3 albedo = mix(ba, oa, final_blend);
	vec3 nrm    = mix(bn, on, final_blend);
	float ao    = mix(bao, oao, final_blend);
	float rough = mix(brough, orough, final_blend);

	// PBR wiring: AO * albedo, roughness from rough map, metallic 0.
	ALBEDO = albedo * ao;
	ROUGHNESS = rough;
	METALLIC = 0.0;
	NORMAL_MAP = mix(vec3(0.5, 0.5, 1.0), nrm, normal_strength); // OpenGL Y+ tangent normal
}
