shader_type spatial;

render_mode diffuse_burley, specular_schlick_ggx, cull_back;

// Textures and scaling
uniform sampler2D height_texture : filter_linear_mipmap;

// Mipmap level used when sampling the heightmap (per-LOD chunk bias).
uniform float height_lod : hint_range(0.0, 8.0) = 0.0;
uniform float amplitude : hint_range(0, 1000) = 200.0;

// Sea level — used as the zero-reference for beach/grass/cliff/snow
// thresholds. The land mesh is NOT clamped to sea level, so the separate
// water plane sees real seafloor geometry underneath.
uniform float sea_level : hint_range(0, 1000) = 100.0;

// Thresholds for different terrain zones (above sea_level). beach_level is
// the nominal top of the sand band (= start of grass).
uniform float beach_level : hint_range(-50.0, 1000) = 5.0;
uniform float cliff_level : hint_range(0, 1000) = 60.0;
uniform float snow_level  : hint_range(0, 1000) = 150.0;

// Safety floor for the sand band: if beach_level is configured at or below
// the waterline, sand is still rendered up to this height so the shoreline
// always shows beach next to the water plane.
uniform float min_shore_sand : hint_range(0.0, 30.0) = 2.0;
// Fraction of biome_boundary_strength applied (upward only) to jitter the
// beach→grass line off a perfect iso-contour. Kept small so beach_level
// stays the dominant control.
uniform float beach_jitter_amount : hint_range(0.0, 1.0) = 0.2;
// Depth below sea level over which the seafloor fades from floor_tint to
// open sand (the wet beach visible through clear shallow water).
uniform float underwater_sand_depth : hint_range(0.0, 50.0) = 6.0;

// --- Surface textures -----------------------------------------------------
// Albedo + tangent-space normal for each blended surface. Sampled triplanar
// in world space so steep cliffs don't smear, at two scales (macro + detail)
// blended by camera distance to break visible tiling up close while staying
// crisp far away. Defaults are neutral so terrain still renders before the
// renderer assigns the generated maps.
uniform sampler2D sand_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D sand_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D grass_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D grass_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D rock_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D snow_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D snow_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D path_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D path_normal : hint_normal, filter_linear_mipmap;
uniform sampler2D road_albedo : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap;

// World size (in world units) of one tile of the detail and macro layers.
uniform float texture_world_size : hint_range(0.5, 40.0) = 6.0;
uniform float macro_world_size : hint_range(8.0, 200.0) = 52.0;
// Camera distance over which the high-frequency detail layer fades out into
// the macro layer (kills tiling shimmer at range).
uniform float detail_fade_start : hint_range(0.0, 800.0) = 60.0;
uniform float detail_fade_end : hint_range(0.0, 1200.0) = 320.0;
// Strength of the texture-derived detail normals.
uniform float detail_normal_strength : hint_range(0.0, 2.0) = 1.0;
// Triplanar blend exponent — higher = tighter switch between projection axes.
uniform float triplanar_sharpness : hint_range(1.0, 16.0) = 6.0;

// Seafloor tint multiplied over the sand texture below the waterline (the
// muted, slightly green submerged shelf seen through the water plane).
uniform vec3 floor_color : source_color = vec3(0.45, 0.55, 0.45);

// Per-surface base roughness (blended by the same biome weights as albedo).
uniform float rough_sand  : hint_range(0.0, 1.0) = 0.9;
uniform float rough_grass : hint_range(0.0, 1.0) = 0.85;
uniform float rough_rock  : hint_range(0.0, 1.0) = 0.78;
uniform float rough_snow  : hint_range(0.0, 1.0) = 0.6;
uniform float rough_track : hint_range(0.0, 1.0) = 0.72;

// Blend width for smooth transitions between terrain zones
uniform float blend_width : hint_range(0.0, 50.0) = 3.0;

// Slope-based cliff blending
uniform float slope_cliff_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float slope_cliff_blend : hint_range(0.0, 0.5) = 0.15;

// Biome boundary noise: jitters the height thresholds so beach/grass/cliff/snow
// lines are no longer straight iso-contours. Wavelength in world units,
// strength in height units.
uniform float biome_boundary_scale : hint_range(1.0, 400.0) = 80.0;
uniform float biome_boundary_strength : hint_range(0.0, 40.0) = 10.0;

// Path/road mask. R = path layer, G = road layer (carved + stamped in
// DrawMatrix3D). Defaults to black so terrain with the feature off is
// unaffected even before a mask is assigned.
uniform sampler2D path_mask : hint_default_black, filter_linear_mipmap;
// Gentle tint pulled toward the editor-exposed path/road colors so those
// controls still bias the carved track without hiding the texture.
uniform vec3 path_color : source_color = vec3(0.42, 0.35, 0.24);
uniform vec3 road_color : source_color = vec3(0.50, 0.50, 0.48);
uniform float track_tint_strength : hint_range(0.0, 1.0) = 0.25;

// Heightmap texel size (set from code or estimate)
uniform vec2 texel_size = vec2(0.002, 0.002);

// Stride (in texels) used for normal gradient sampling. Wider = smoother.
uniform float normal_sample_stride : hint_range(0.5, 8.0) = 2.0;

varying vec3 v_heightmap_normal;
varying vec3 v_world_pos;

// Simple hash-based noise (no texture needed)
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 3; i++) {
        val += amp * value_noise(p);
        p *= 2.1;
        amp *= 0.5;
    }
    return val;
}

// Triplanar blend weights from a world-space normal.
vec3 tri_weights(vec3 wn) {
    vec3 w = pow(abs(wn), vec3(triplanar_sharpness));
    return w / max(w.x + w.y + w.z, 1e-4);
}

// Triplanar colour sample at a given world tile scale.
vec3 tri_albedo(sampler2D tex, vec3 wp, vec3 bw, float inv_size) {
    vec3 x = texture(tex, wp.zy * inv_size).rgb;
    vec3 y = texture(tex, wp.xz * inv_size).rgb;
    vec3 z = texture(tex, wp.xy * inv_size).rgb;
    return x * bw.x + y * bw.y + z * bw.z;
}

// Macro+detail anti-tiling albedo: two octaves blended by detail visibility.
vec3 surf_albedo(sampler2D tex, vec3 wp, vec3 bw, float detail_vis) {
    vec3 d = tri_albedo(tex, wp, bw, 1.0 / texture_world_size);
    vec3 m = tri_albedo(tex, wp, bw, 1.0 / macro_world_size);
    return mix(m, d, detail_vis);
}

// Triplanar tangent-space-ish detail normal (single, detail-scale octave).
vec3 surf_normal(sampler2D tex, vec3 wp, vec3 bw) {
    float s = 1.0 / texture_world_size;
    vec3 nx = texture(tex, wp.zy * s).xyz * 2.0 - 1.0;
    vec3 ny = texture(tex, wp.xz * s).xyz * 2.0 - 1.0;
    vec3 nz = texture(tex, wp.xy * s).xyz * 2.0 - 1.0;
    return normalize(nx * bw.x + ny * bw.y + nz * bw.z);
}

void vertex() {
    // Displacement always samples mipmap 0 so adjacent chunks at different
    // LODs agree on height at their shared edge — otherwise you can see
    // through the seams.
    float height_val = textureLod(height_texture, UV, 0.0).r * amplitude;
    VERTEX.y += height_val;

    // Normals can still widen their sample stride at lower LODs for smoother
    // distant shading; mismatched normals between chunks don't cause gaps.
    float stride = normal_sample_stride * exp2(height_lod);
    vec2 ns = texel_size * stride;
    float h_r = textureLod(height_texture, UV + vec2(ns.x, 0.0), 0.0).r * amplitude;
    float h_l = textureLod(height_texture, UV - vec2(ns.x, 0.0), 0.0).r * amplitude;
    float h_u = textureLod(height_texture, UV + vec2(0.0, ns.y), 0.0).r * amplitude;
    float h_d = textureLod(height_texture, UV - vec2(0.0, ns.y), 0.0).r * amplitude;
    v_heightmap_normal = normalize(vec3(h_l - h_r, 2.0 * stride, h_d - h_u));
    NORMAL = v_heightmap_normal;

    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    float raw_height = textureLod(height_texture, UV, height_lod).r * amplitude;
    float h = raw_height - sea_level;

    float h_r = textureLod(height_texture, UV + vec2(texel_size.x, 0.0), height_lod).r * amplitude;
    float h_l = textureLod(height_texture, UV - vec2(texel_size.x, 0.0), height_lod).r * amplitude;
    float h_u = textureLod(height_texture, UV + vec2(0.0, texel_size.y), height_lod).r * amplitude;
    float h_d = textureLod(height_texture, UV - vec2(0.0, texel_size.y), height_lod).r * amplitude;
    vec3 heightmap_normal = normalize(vec3(h_l - h_r, 2.0, h_d - h_u));

    float slope = 1.0 - heightmap_normal.y;

    // Symmetric noise wanders the upper biome boundaries off straight contours.
    float boundary_offset = (fbm(v_world_pos.xz / max(biome_boundary_scale, 1.0)) - 0.5) * 2.0 * biome_boundary_strength;
    float h_biome = h + boundary_offset;
    // Asymmetric, scaled-down jitter for the beach→grass boundary: only push
    // the grass line higher (never into the sand strip) and only by a small
    // fraction so beach_level remains the visible control.
    float beach_jitter = max(boundary_offset, 0.0) * beach_jitter_amount;

    // Effective top of sand: beach_level is authoritative; min_shore_sand only
    // catches the case where it's configured at or below the waterline.
    float beach_top = max(beach_level, min_shore_sand) + beach_jitter;

    // --- Biome weights (identical math to the old colour blend, kept as
    // explicit mix() chain so albedo, normal and roughness stay consistent).
    float underwater_sand_t = smoothstep(-max(underwater_sand_depth, 0.001), 0.0, h);
    float grass_t = smoothstep(beach_top - blend_width * 0.5, beach_top + blend_width * 0.5, h);
    float cliff_t = smoothstep(cliff_level - blend_width * 0.5, cliff_level + blend_width * 0.5, h_biome);
    float snow_t  = smoothstep(snow_level - blend_width * 0.5, snow_level + blend_width * 0.5, h_biome);
    float slope_factor = smoothstep(
        slope_cliff_threshold - slope_cliff_blend,
        slope_cliff_threshold + slope_cliff_blend,
        slope
    );
    // Suppress the slope-driven rock overlay inside the shore band so steep
    // little dunes at the waterline still read as sand, not cliff.
    float above_shore = smoothstep(beach_top * 0.5, max(beach_top * 1.5, beach_top + blend_width), h);
    float rock_slope = slope_factor * above_shore;

    // Paths/roads only above the waterline so a route grazing the shore never
    // paints onto submerged seafloor.
    vec2 pr = textureLod(path_mask, UV, height_lod).rg;
    float land = smoothstep(0.0, blend_width, h);
    float path_m = pr.r * land;
    float road_m = pr.g * land;
    float track = max(path_m, road_m);

    // --- Texture sampling -------------------------------------------------
    vec3 bw = tri_weights(heightmap_normal);
    float cam_dist = length(v_world_pos - CAMERA_POSITION_WORLD);
    float detail_vis = 1.0 - smoothstep(detail_fade_start, max(detail_fade_end, detail_fade_start + 1.0), cam_dist);

    vec3 t_sand  = surf_albedo(sand_albedo,  v_world_pos, bw, detail_vis);
    vec3 t_grass = surf_albedo(grass_albedo, v_world_pos, bw, detail_vis);
    vec3 t_rock  = surf_albedo(rock_albedo,  v_world_pos, bw, detail_vis);
    vec3 t_snow  = surf_albedo(snow_albedo,  v_world_pos, bw, detail_vis);
    vec3 t_path  = surf_albedo(path_albedo,  v_world_pos, bw, detail_vis);
    vec3 t_road  = surf_albedo(road_albedo,  v_world_pos, bw, detail_vis);

    // Submerged shelf: tint the sand toward the muted seafloor colour.
    vec3 base = t_sand * mix(floor_color, vec3(1.0), underwater_sand_t);

    vec3 color = base;
    vec3 nrm = surf_normal(sand_normal, v_world_pos, bw);

    color = mix(color, t_grass, grass_t);
    nrm = mix(nrm, surf_normal(grass_normal, v_world_pos, bw), grass_t);

    color = mix(color, t_rock, cliff_t);
    nrm = mix(nrm, surf_normal(rock_normal, v_world_pos, bw), cliff_t);

    color = mix(color, t_snow, snow_t);
    nrm = mix(nrm, surf_normal(snow_normal, v_world_pos, bw), snow_t);

    // Slope-driven rock overlay reuses the rock maps.
    color = mix(color, t_rock, rock_slope);
    nrm = mix(nrm, surf_normal(rock_normal, v_world_pos, bw), rock_slope);

    // Tracks: dirt for paths, gravel for roads, with a gentle pull toward the
    // editor-exposed path/road colours.
    vec3 path_col = mix(t_path, t_path * (path_color * 2.0), track_tint_strength);
    vec3 road_col = mix(t_road, t_road * (road_color * 2.0), track_tint_strength);
    color = mix(color, path_col, path_m);
    nrm = mix(nrm, surf_normal(path_normal, v_world_pos, bw), path_m);
    color = mix(color, road_col, road_m);
    nrm = mix(nrm, surf_normal(road_normal, v_world_pos, bw), road_m);

    nrm = normalize(mix(vec3(0.0, 0.0, 1.0), nrm, detail_normal_strength * detail_vis));

    // Per-surface roughness blended with the same weights.
    float rough = rough_sand;
    rough = mix(rough, rough_grass, grass_t);
    rough = mix(rough, rough_rock, cliff_t);
    rough = mix(rough, rough_snow, snow_t);
    rough = mix(rough, rough_rock, rock_slope);
    rough = mix(rough, rough_track, track);

    NORMAL_MAP = nrm * 0.5 + 0.5;
    NORMAL_MAP_DEPTH = 1.0;
    ROUGHNESS = rough;
    METALLIC = 0.0;
    SPECULAR = 0.2;
    ALBEDO = color;
}
