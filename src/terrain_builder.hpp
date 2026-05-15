#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <vector>
#include <cstdint>
#include <random>
#include <utility>

namespace godot
{
  // Owns the whole heightmap pipeline so there is one source of truth:
  // DTL matrix -> box blur -> seeded path/road networks (full-resolution A*
  // around steep terrain) -> grade-limited carve with slope-limited shoulders
  // -> normalized RF height texture + RG path/road mask texture.
  //
  // DrawMatrix3D just holds the inspector config and calls build(); TerrainLOD
  // and the water plane consume the textures DrawMatrix3D exposes.
  class TerrainBuilder : public RefCounted
  {
    GDCLASS(TerrainBuilder, RefCounted);

  protected:
    static void _bind_methods();

  public:
    TerrainBuilder();
    ~TerrainBuilder();

    // cfg keys (all optional, sensible defaults): amplitude, sea_level,
    // terrain_size, paths_enabled, roads_enabled, seed, path_node_count,
    // road_node_count, path_width, road_width, path_max_grade,
    // road_max_grade, hill_avoidance.
    // Returns { "height": ImageTexture, "mask": ImageTexture }.
    Dictionary build(Array matrix, Dictionary cfg);

  private:
    int w = 0;
    int h = 0;
    float amplitude = 100.0f;
    float sea_level = 0.0f;
    float terrain_size = 1000.0f;
    float lowest = 0.0f;
    float range = 1.0f;
    float world_per_texel = 1.0f;
    float world_per_buf = 1.0f;
    float hill_avoidance = 0.7f;

    std::vector<float> buf;  // working heights (DTL units), carved in place
    std::vector<float> orig; // natural reference for shoulder fillets
    std::vector<float> mask; // w*h*2, R = path, G = road

    // Carve accumulation (build-scoped). Every route blends into these; then
    // build() composites them onto buf in one pass and relaxes the result, so
    // parallel passes and path/road crossings merge smoothly instead of
    // stair-stepping into walls.
    std::vector<float> acc_h;    // sum(weight * road bed height, world)
    std::vector<float> acc_w;    // sum(weight)
    std::vector<float> max_infl; // strongest road influence (0..1) per texel

    // A* scratch, allocated once and reused per edge.
    std::vector<float> g_cost;
    std::vector<int32_t> came;
    std::vector<uint8_t> closed;

    inline float h_world(float b) const { return (b - lowest) / range * amplitude; }
    inline float world_to_buf(float wh) const { return lowest + wh / (amplitude > 1e-4f ? amplitude : 1e-4f) * range; }
    float local_steepness(int x, int y) const;

    void box_blur_2x();
    void build_network(std::mt19937 &rng, int node_count, float width_world,
                        float max_grade, int mask_channel);
    std::vector<int> astar(int sx, int sy, int gx, int gy);
    void carve_route(const std::vector<std::pair<float, float>> &poly,
                     float width_world, float max_grade, int mask_channel);
  };
}
