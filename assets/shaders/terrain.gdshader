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
// Depth below sea level over which the seafloor fades from floor_color to
// beach_color (the wet beach visible through clear shallow water).
uniform float underwater_sand_depth : hint_range(0.0, 50.0) = 6.0;

// Colors for different zones. floor_color is the seafloor tint that shows
// through the (transparent) water near shore.
uniform vec3 floor_color  : source_color = vec3(0.25, 0.30, 0.25);
uniform vec3 beach_color  : source_color = vec3(0.9, 0.8, 0.4);
uniform vec3 grass_color  : source_color = vec3(0.2, 0.6, 0.1);
uniform vec3 cliff_color  : source_color = vec3(0.5, 0.5, 0.4);
uniform vec3 snow_color   : source_color = vec3(1.0, 1.0, 1.0);

// Blend width for smooth transitions between terrain zones
uniform float blend_width : hint_range(0.0, 50.0) = 3.0;

// Slope-based cliff blending
uniform float slope_cliff_threshold : hint_range(0.0, 1.0) = 0.6;
uniform float slope_cliff_blend : hint_range(0.0, 0.5) = 0.15;

// Color variation noise (world-space wavelength in world units)
uniform float noise_strength : hint_range(0.0, 0.2) = 0.06;
uniform float noise_scale : hint_range(1.0, 200.0) = 18.0;

// Biome boundary noise: jitters the height thresholds so beach/grass/cliff/snow
// lines are no longer straight iso-contours. Wavelength in world units,
// strength in height units.
uniform float biome_boundary_scale : hint_range(1.0, 400.0) = 80.0;
uniform float biome_boundary_strength : hint_range(0.0, 40.0) = 10.0;

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

    // Wet beach: floor_color fades up to beach_color across the shallow shelf.
    float underwater_sand_t = smoothstep(-max(underwater_sand_depth, 0.001), 0.0, h);
    vec3 color = mix(floor_color, beach_color, underwater_sand_t);

    // Sand → grass.
    float grass_t = smoothstep(beach_top - blend_width * 0.5, beach_top + blend_width * 0.5, h);
    color = mix(color, grass_color, grass_t);

    // Higher biome bands keep symmetric noise so the cliff/snow lines wander
    // naturally on both sides.
    float cliff_t = smoothstep(cliff_level - blend_width * 0.5, cliff_level + blend_width * 0.5, h_biome);
    float snow_t  = smoothstep(snow_level - blend_width * 0.5, snow_level + blend_width * 0.5, h_biome);
    color = mix(color, cliff_color, cliff_t);
    color = mix(color, snow_color, snow_t);

    float slope_factor = smoothstep(
        slope_cliff_threshold - slope_cliff_blend,
        slope_cliff_threshold + slope_cliff_blend,
        slope
    );
    // Suppress the slope-driven rock overlay inside the shore band so steep
    // little dunes at the waterline still read as sand, not cliff.
    float above_shore = smoothstep(beach_top * 0.5, max(beach_top * 1.5, beach_top + blend_width), h);
    color = mix(color, cliff_color, slope_factor * above_shore);

    // World-space color variation so the pattern is continuous across chunks.
    float n = fbm(v_world_pos.xz / max(noise_scale, 1.0));
    color += (n - 0.5) * 2.0 * noise_strength;

    NORMAL_MAP = heightmap_normal * 0.5 + 0.5;
    ROUGHNESS = mix(0.85, 0.95, slope_factor);
    METALLIC = 0.0;
    SPECULAR = 0.2;
    ALBEDO = color;
}
