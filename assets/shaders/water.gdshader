shader_type spatial;

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Heightmap that the land uses — lets us know where the seafloor sits under
// each water fragment without needing the depth buffer.
uniform sampler2D height_texture : filter_linear_mipmap;
uniform float amplitude : hint_range(0, 1000) = 200.0;
uniform float sea_level : hint_range(0, 1000) = 100.0;

// Full extent of the terrain in world units; used to map world.xz → UV.
uniform float terrain_size = 2000.0;

// Colors — depth ramp goes shallow → ocean → deep so the shoreline reads
// turquoise before falling into the deeper blue.
uniform vec3 shallow_color : source_color = vec3(0.30, 0.72, 0.75);
uniform vec3 ocean_color : source_color = vec3(0.05, 0.35, 0.55);
uniform vec3 ocean_deep_color : source_color = vec3(0.0, 0.1, 0.22);
uniform vec3 fresnel_color : source_color = vec3(0.6, 0.8, 0.95);
uniform vec3 edge_color : source_color = vec3(0.85, 0.95, 1.0);

// Shape
uniform float fresnel_power : hint_range(0.5, 8.0) = 3.0;
uniform float shallow_fade : hint_range(0.1, 80.0) = 12.0; // turquoise → ocean
uniform float depth_fade : hint_range(0.1, 400.0) = 60.0;  // ocean → deep
uniform float alpha_depth : hint_range(0.1, 200.0) = 8.0;  // alpha saturation
uniform float max_alpha : hint_range(0.0, 1.0) = 0.92;

// Shore foam
uniform float edge_width : hint_range(0.0, 30.0) = 5.0;
uniform float edge_intensity : hint_range(0.0, 2.0) = 0.9;
uniform float edge_sharpness : hint_range(0.1, 10.0) = 1.5;

// Wave animation (world-space). Two swell layers drift in different directions
// and a fast fine-scale ripple rides on top.
uniform float wave_speed : hint_range(0.0, 5.0) = 0.35;
uniform float wave_scale : hint_range(1.0, 400.0) = 80.0;
uniform float wave_strength : hint_range(0.0, 1.0) = 0.2;
uniform float ripple_scale : hint_range(0.5, 40.0) = 8.0;
uniform float ripple_strength : hint_range(0.0, 1.0) = 0.25;
// Multiplier on the per-fragment wave gradient. Larger = choppier normals
// without affecting the vertex displacement.
uniform float normal_bump : hint_range(0.1, 8.0) = 4.0;

// PBR knobs. peak_roughness is used on wave crests so they catch sharp
// highlights while troughs stay slightly matte.
uniform float water_specular : hint_range(0.0, 1.0) = 0.8;
uniform float water_metallic : hint_range(0.0, 1.0) = 0.1;
uniform float water_roughness : hint_range(0.0, 1.0) = 0.08;
uniform float peak_roughness : hint_range(0.0, 1.0) = 0.02;

varying vec3 v_world_pos;

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
    for (int i = 0; i < 4; i++) {
        val += amp * value_noise(p);
        p = p * 2.1 + vec2(17.3, 7.7);
        amp *= 0.5;
    }
    return val;
}

// Elevation of the animated surface at a world-space xz, before scaling.
// Two counter-drifting swells keep the pattern from looking like a single
// repeating noise field, and the small ripple adds per-pixel detail.
float wave_height(vec2 xz) {
    vec2 dir_a = vec2(0.72, 0.38);
    vec2 dir_b = vec2(-0.44, 0.86);
    float w_a = fbm(xz / max(wave_scale, 1.0) + TIME * wave_speed * dir_a) - 0.5;
    float w_b = fbm(xz / max(wave_scale * 0.45, 1.0) + TIME * wave_speed * 1.4 * dir_b) - 0.5;
    float w_r = fbm(xz / max(ripple_scale, 1.0) + TIME * wave_speed * 3.1 * dir_a) - 0.5;
    return w_a + w_b * 0.55 + w_r * ripple_strength;
}

// Signed distance to sea level — positive over land, negative under water.
float sample_floor_height(vec2 world_xz) {
    vec2 uv = world_xz / max(terrain_size, 1.0) + 0.5;
    // Outside the heightmap we treat the floor as far below sea level so
    // water past the terrain edge looks like open ocean.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return -amplitude;
    }
    return texture(height_texture, uv).r * amplitude - sea_level;
}

void vertex() {
    vec3 wpos_pre = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    VERTEX.y += wave_height(wpos_pre.xz) * wave_strength * 4.0;
    v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    float floor_h = sample_floor_height(v_world_pos.xz);
    float depth = max(-floor_h, 0.0);

    // Three-stop depth ramp: shallow turquoise → ocean → deep.
    float shallow_t = clamp(depth / max(shallow_fade, 0.001), 0.0, 1.0);
    vec3 color = mix(shallow_color, ocean_color, shallow_t);
    float deep_t = clamp((depth - shallow_fade) / max(depth_fade, 0.001), 0.0, 1.0);
    color = mix(color, ocean_deep_color, deep_t);

    float alpha_t = clamp(depth / max(alpha_depth, 0.001), 0.0, 1.0);
    float alpha = alpha_t * max_alpha;

    // World-space wave gradient via forward differences; convert the 0..1
    // noise space into actual world-unit height first so normal_bump has
    // physical meaning independent of wave_scale.
    float eps = 0.5;
    float h_scale = wave_strength * 4.0;
    float hc = wave_height(v_world_pos.xz) * h_scale;
    float hx = wave_height(v_world_pos.xz + vec2(eps, 0.0)) * h_scale;
    float hz = wave_height(v_world_pos.xz + vec2(0.0, eps)) * h_scale;
    vec2 grad = vec2(hx - hc, hz - hc) / eps;
    // Tangent-space normal. Z is the outward axis for Godot's NORMAL_MAP so
    // a flat surface encodes as (0,0,1); the x/y components are the negated
    // slope, scaled by normal_bump for artistic control.
    vec3 wave_n = normalize(vec3(-grad.x * normal_bump, -grad.y * normal_bump, 1.0));
    NORMAL_MAP = wave_n * 0.5 + 0.5;

    // Fresnel sky tint — only uses the mesh normal (cheap, and the wave
    // perturbation still shows up through specular).
    float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
    color = mix(color, fresnel_color, fresnel * 0.55);

    // Foam: strongest at the waterline, falling off over edge_width. Wave
    // crests near the shore get a second pass of foam so breaking waves read
    // as whitecaps instead of disappearing into the blue.
    float edge_foam = 1.0 - smoothstep(0.0, max(edge_width, 0.001), depth);
    edge_foam = pow(edge_foam, edge_sharpness);
    float foam_noise = fbm(v_world_pos.xz * 0.12 + TIME * wave_speed * 0.6);
    edge_foam *= mix(0.55, 1.0, foam_noise);
    float crest = smoothstep(0.05, 0.32, hc);
    float crest_band = 1.0 - smoothstep(0.0, edge_width * 2.5, depth);
    edge_foam = max(edge_foam, crest * crest_band * 0.7);
    float foam_mix = clamp(edge_foam * edge_intensity, 0.0, 1.0);
    color = mix(color, edge_color, foam_mix);
    alpha = max(alpha, foam_mix);

    // Wave-crest sparkle: lower roughness on peaks gives tight specular
    // highlights while troughs keep the softer base roughness.
    float peak_t = smoothstep(-0.15 * h_scale, 0.30 * h_scale, hc);
    float roughness = mix(water_roughness, peak_roughness, peak_t);

    ALBEDO = color;
    ALPHA = alpha;
    SPECULAR = water_specular;
    METALLIC = water_metallic;
    ROUGHNESS = roughness;
}
