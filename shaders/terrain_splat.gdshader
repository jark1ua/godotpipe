shader_type spatial;
// Starter terrain splat shader.
// Blends 4 tiling layer textures by the world splatmap baked in Blender.
// Splatmap channels: R = grass, G = rock, B = snow, A = sand.
//
// Each chunk's mesh has a per-vertex UV that runs 0..1 across the WHOLE world,
// so all chunks sample one shared splatmap seamlessly. The same UV, scaled up,
// drives the tiling of the detail textures (also seamless across chunk borders).

uniform sampler2D splatmap : filter_linear_mipmap;
uniform sampler2D tex_grass : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_rock  : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_snow  : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_sand  : source_color, filter_linear_mipmap_anisotropic;

uniform float world_size_m = 6000.0; // matches manifest world_size_m
uniform float tile_m = 12.0;         // metres covered by one tile of a detail texture
uniform float layer_roughness = 1.0;

varying vec2 splat_uv;

void vertex() {
	splat_uv = UV;
}

void fragment() {
	vec4 w = texture(splatmap, splat_uv);
	w /= max(w.r + w.g + w.b + w.a, 1e-4); // ensure weights sum to 1

	vec2 tuv = splat_uv * (world_size_m / tile_m);
	vec3 col =
		  texture(tex_grass, tuv).rgb * w.r
		+ texture(tex_rock,  tuv).rgb * w.g
		+ texture(tex_snow,  tuv).rgb * w.b
		+ texture(tex_sand,  tuv).rgb * w.a;

	ALBEDO = col;
	ROUGHNESS = layer_roughness;
}
