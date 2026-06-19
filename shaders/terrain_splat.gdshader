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

// Parallax Occlusion Mapping (real ray-marched relief from the height maps).
// Marches the base layer's height field along the tangent-space view direction,
// finds the occluded intersection, and shifts the detail UV there — so the ground
// shows true depth and parallax at grazing angles, not just a single-tap skew.
// Applied to near-flat ground only (skipped on steep/triplanar faces, where the
// world-XZ UV plane is invalid). The control map is always sampled at the
// un-parallaxed UV, so POM never changes which layer lives where.
uniform bool enable_parallax = true;
uniform float parallax_scale : hint_range(0.0, 0.5) = 0.08;    // apparent depth, fraction of a tile
uniform float parallax_min_view : hint_range(0.05, 1.0) = 0.3; // clamp at grazing angles
uniform int parallax_min_steps : hint_range(2, 32) = 8;        // march steps looking straight down
uniform int parallax_max_steps : hint_range(4, 64) = 32;       // march steps at grazing angles

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// Sample one layer's maps at this fragment. Albedo + normal get triplanar on
// steep eligible layers; ao/rough/height stay planar (cheaper, barely visible).
// world_off is a parallax shift (metres, world XZ) applied to the planar sample.
void sample_layer(int layer, vec2 world_off, float tri_amt, vec3 tri_w,
		out vec3 albedo, out vec3 nrm, out float ao, out float rough, out float height) {
	float tile = layer_tile_m[layer] > 0.0 ? layer_tile_m[layer] : default_tile_m;
	vec2 puv = (v_world_pos.xz + world_off) / tile;
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

// Parallax Occlusion Mapping. Marches a layer's height field along the tangent-
// space view direction and returns the detail-UV offset (in tile/UV units) at the
// occluded hit. view_ts = view dir (surface->camera) in the flat-ground tangent
// frame (x = +X tangent, y = +Z bitangent, z = +Y normal); fl is the layer slice.
vec2 pom_offset(vec2 base_uv, vec3 view_ts, float fl) {
	float ndotv = max(view_ts.z, parallax_min_view);
	// More steps at grazing angles (view_ts.z small), fewer looking straight down.
	float n_steps = mix(float(parallax_max_steps), float(parallax_min_steps),
			clamp(view_ts.z, 0.0, 1.0));
	float layer_depth = 1.0 / n_steps;
	// Total UV shift corresponding to the full apparent depth.
	vec2 P = (view_ts.xy / ndotv) * parallax_scale;
	vec2 delta_uv = P / n_steps;

	// textureLod (explicit LOD 0): derivatives are undefined inside this divergent
	// loop, so a plain texture() would be ill-defined. LOD 0 height is fine to march.
	float cur_depth = 0.0;
	vec2 cur_uv = base_uv;
	float surf_depth = 1.0 - textureLod(height_array, vec3(cur_uv, fl), 0.0).r;
	for (int i = 0; i < 64; i++) {
		if (float(i) >= n_steps || cur_depth >= surf_depth) break;
		cur_uv -= delta_uv;
		cur_depth += layer_depth;
		surf_depth = 1.0 - textureLod(height_array, vec3(cur_uv, fl), 0.0).r;
	}
	// Refine: interpolate between the last two samples around the crossing.
	vec2 prev_uv = cur_uv + delta_uv;
	float after = surf_depth - cur_depth;
	float before = (1.0 - textureLod(height_array, vec3(prev_uv, fl), 0.0).r) - (cur_depth - layer_depth);
	float w = after / max(after - before, 1e-5);
	vec2 hit_uv = mix(cur_uv, prev_uv, clamp(w, 0.0, 1.0));
	return hit_uv - base_uv;
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

	// Parallax Occlusion Mapping offset (world XZ metres) from the base layer's
	// height field. Skipped on steep/triplanar faces (the world-XZ UV plane is
	// invalid there) and faded out as the slope ramps into triplanar.
	vec2 world_off = vec2(0.0);
	if (enable_parallax && tri_amt < 0.999) {
		vec3 wv = normalize(CAMERA_POSITION_WORLD - v_world_pos);
		// Flat-ground tangent frame: T=+X, B=+Z, N=+Y -> view dir in tangent space.
		vec3 view_ts = vec3(wv.x, wv.z, wv.y);
		float btile = layer_tile_m[base_l] > 0.0 ? layer_tile_m[base_l] : default_tile_m;
		vec2 base_uv = v_world_pos.xz / btile;
		vec2 uv_off = pom_offset(base_uv, view_ts, float(base_l));
		// UV offset (base-layer tiles) -> physical metres on the ground, so each
		// layer re-derives its own UV shift from its own tile size in sample_layer.
		world_off = uv_off * btile * (1.0 - tri_amt);
	}

	vec3 ba, bn; float bao, brough, bh;
	vec3 oa, on; float oao, orough, oh;
	sample_layer(base_l, world_off, tri_amt, tri_w, ba, bn, bao, brough, bh);
	sample_layer(over_l, world_off, tri_amt, tri_w, oa, on, oao, orough, oh);

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
