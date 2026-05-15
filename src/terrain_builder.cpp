#include "terrain_builder.hpp"

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <utility>

using namespace godot;

TerrainBuilder::TerrainBuilder() {}
TerrainBuilder::~TerrainBuilder() {}

void TerrainBuilder::_bind_methods()
{
  ClassDB::bind_method(D_METHOD("build", "matrix", "cfg"), &TerrainBuilder::build);
}

static inline float cfg_f(const Dictionary &c, const char *k, float d)
{
  return c.has(k) ? (float)(double)c[k] : d;
}
static inline int cfg_i(const Dictionary &c, const char *k, int d)
{
  return c.has(k) ? (int)c[k] : d;
}
static inline bool cfg_b(const Dictionary &c, const char *k, bool d)
{
  return c.has(k) ? (bool)c[k] : d;
}
static inline float clampf_(float v, float lo, float hi)
{
  return v < lo ? lo : (v > hi ? hi : v);
}
static inline float lerpf_(float a, float b, float t) { return a + (b - a) * t; }

// Chaikin corner-cutting. The A* route is an 8-connected staircase; this
// rounds it into a smooth curve while pinning the endpoints so networks stay
// connected at the waypoints.
static std::vector<std::pair<float, float>> chaikin(
    const std::vector<std::pair<float, float>> &p, int iters)
{
  std::vector<std::pair<float, float>> cur = p;
  for (int it = 0; it < iters && cur.size() >= 3; it++)
  {
    std::vector<std::pair<float, float>> nx;
    nx.reserve(cur.size() * 2);
    nx.push_back(cur.front());
    for (size_t i = 0; i + 1 < cur.size(); i++)
    {
      const auto &a = cur[i];
      const auto &b = cur[i + 1];
      nx.push_back({0.75f * a.first + 0.25f * b.first, 0.75f * a.second + 0.25f * b.second});
      nx.push_back({0.25f * a.first + 0.75f * b.first, 0.25f * a.second + 0.75f * b.second});
    }
    nx.push_back(cur.back());
    cur.swap(nx);
  }
  return cur;
}

float TerrainBuilder::local_steepness(int x, int y) const
{
  float b = buf[y * w + x];
  float d = 0.0f;
  if (x + 1 < w)
    d = std::max(d, std::fabs(buf[y * w + x + 1] - b));
  if (x > 0)
    d = std::max(d, std::fabs(buf[y * w + x - 1] - b));
  if (y + 1 < h)
    d = std::max(d, std::fabs(buf[(y + 1) * w + x] - b));
  if (y > 0)
    d = std::max(d, std::fabs(buf[(y - 1) * w + x] - b));
  return d * world_per_buf / world_per_texel;
}

void TerrainBuilder::box_blur_2x()
{
  // Two 3x3 box blur passes (~5x5 Gaussian) smooth DTL's integer step
  // quantization — one pass isn't enough for dense maps with many octaves.
  std::vector<float> tmp(buf.size());
  std::vector<float> *src = &buf;
  std::vector<float> *dst = &tmp;
  for (int pass = 0; pass < 2; pass++)
  {
    for (int y = 0; y < h; y++)
    {
      for (int x = 0; x < w; x++)
      {
        float sum = 0.0f;
        int cnt = 0;
        for (int dy = -1; dy <= 1; dy++)
        {
          int ny = y + dy;
          if (ny < 0 || ny >= h)
            continue;
          for (int dx = -1; dx <= 1; dx++)
          {
            int nx = x + dx;
            if (nx < 0 || nx >= w)
              continue;
            sum += (*src)[ny * w + nx];
            cnt++;
          }
        }
        (*dst)[y * w + x] = sum / (float)cnt;
      }
    }
    std::swap(src, dst);
  }
  if (src != &buf)
    buf = *src;
}

// Full-resolution A*. Edge cost = world distance scaled up quadratically by
// the per-texel grade so the search detours around steep ground; grades over
// the cap are impassable (the goal cell is always reachable so a waypoint on
// rough ground still terminates). No coarse grid — at full res a cliff is
// never hidden between samples.
std::vector<int> TerrainBuilder::astar(int sx, int sy, int gx, int gy)
{
  float slope_weight = lerpf_(2.0f, 24.0f, hill_avoidance);
  float hard_cap = lerpf_(1.2f, 0.30f, hill_avoidance);
  const int total = w * h;
  const int start = sy * w + sx;
  const int goal = gy * w + gx;
  const float diag = 1.41421356f;

  static const int nx8[8] = {1, -1, 0, 0, 1, 1, -1, -1};
  static const int ny8[8] = {0, 0, 1, -1, 1, -1, 1, -1};

  for (int relax = 0; relax < 2; relax++)
  {
    float cap = (relax == 0) ? hard_cap : hard_cap * 2.5f;

    std::fill(g_cost.begin(), g_cost.end(), std::numeric_limits<float>::infinity());
    std::fill(came.begin(), came.end(), -1);
    std::fill(closed.begin(), closed.end(), (uint8_t)0);

    using QN = std::pair<float, int>;
    std::priority_queue<QN, std::vector<QN>, std::greater<QN>> open;

    g_cost[start] = 0.0f;
    float hx = (float)(sx - gx), hy = (float)(sy - gy);
    open.push({std::sqrt(hx * hx + hy * hy) * world_per_texel, start});

    bool found = false;
    while (!open.empty())
    {
      int cur = open.top().second;
      open.pop();
      if (cur == goal)
      {
        found = true;
        break;
      }
      if (closed[cur])
        continue;
      closed[cur] = 1;
      int cx = cur % w;
      int cy = cur / w;
      float ha = h_world(buf[cur]);
      float steep_cur = local_steepness(cx, cy);
      for (int k = 0; k < 8; k++)
      {
        int nx = cx + nx8[k];
        int ny = cy + ny8[k];
        if (nx < 0 || nx >= w || ny < 0 || ny >= h)
          continue;
        int ni = ny * w + nx;
        if (closed[ni])
          continue;
        float dist = world_per_texel;
        if (nx8[k] != 0 && ny8[k] != 0)
          dist *= diag;
        // Effective steepness = the worse of the along-track grade and the
        // terrain's own steepest local face at either cell. The cross-slope
        // term is what stops the route from sidehilling across a steep face
        // (low along-track slope, but a tall cut/fill once carved flat) —
        // i.e. it routes *around* the hill, not along its side.
        float along = std::fabs(h_world(buf[ni]) - ha) / dist;
        float slope = std::max(along, std::max(steep_cur, local_steepness(nx, ny)));
        if (slope > cap && ni != goal)
          continue;
        float r = slope / cap;
        float step = dist * (1.0f + slope_weight * r * r);
        float tentative = g_cost[cur] + step;
        if (tentative < g_cost[ni])
        {
          g_cost[ni] = tentative;
          came[ni] = cur;
          float ex = (float)(nx - gx), ey = (float)(ny - gy);
          open.push({tentative + std::sqrt(ex * ex + ey * ey) * world_per_texel, ni});
        }
      }
    }

    if (!found && goal != start)
      continue;

    std::vector<int> path;
    int node = goal;
    while (node != -1)
    {
      path.push_back(node);
      if (node == start)
        break;
      node = came[node];
    }
    std::reverse(path.begin(), path.end());
    if (path.size() >= 2)
      return path;
  }
  return std::vector<int>();
}

void TerrainBuilder::carve_route(const std::vector<std::pair<float, float>> &poly,
                                 float width_world, float max_grade, int mask_channel)
{
  // Sample spacing tied to road width: the carve uses true distance to the
  // nearest sample, so overlapping samples a fraction of a width apart give a
  // smooth distance field cheaply.
  float wr = std::max(1.0f, (width_world * 0.5f) / world_per_texel);
  float spacing = std::max(1.0f, wr * 0.75f);

  std::vector<std::pair<float, float>> pts;
  for (size_t i = 0; i + 1 < poly.size(); i++)
  {
    float dx = poly[i + 1].first - poly[i].first;
    float dy = poly[i + 1].second - poly[i].second;
    float len = std::sqrt(dx * dx + dy * dy);
    int steps = std::max(1, (int)std::ceil(len / spacing));
    for (int s = 0; s < steps; s++)
    {
      float t = (float)s / (float)steps;
      pts.push_back({poly[i].first + dx * t, poly[i].second + dy * t});
    }
  }
  {
    pts.push_back(poly.back());
  }
  if (pts.size() < 2)
    return;

  // Centerline surface height (world) from the natural terrain, grade-limited
  // forward+backward then smoothed so it climbs gently — the longitudinal
  // "not too steep" constraint.
  float sea_world = sea_level;
  std::vector<float> surf(pts.size());
  for (size_t i = 0; i < pts.size(); i++)
  {
    int px = std::clamp((int)std::lround(pts[i].first), 0, w - 1);
    int py = std::clamp((int)std::lround(pts[i].second), 0, h - 1);
    surf[i] = std::max(h_world(orig[py * w + px]), sea_world + 0.01f * amplitude);
  }
  for (int it = 0; it < 8; it++)
  {
    for (size_t i = 1; i < pts.size(); i++)
    {
      float dx = pts[i].first - pts[i - 1].first, dy = pts[i].second - pts[i - 1].second;
      float seg = std::max(std::sqrt(dx * dx + dy * dy) * world_per_texel, 0.001f);
      float md = max_grade * seg;
      surf[i] = clampf_(surf[i], surf[i - 1] - md, surf[i - 1] + md);
    }
    for (int i = (int)pts.size() - 2; i >= 0; i--)
    {
      float dx = pts[i + 1].first - pts[i].first, dy = pts[i + 1].second - pts[i].second;
      float seg = std::max(std::sqrt(dx * dx + dy * dy) * world_per_texel, 0.001f);
      float md = max_grade * seg;
      surf[i] = clampf_(surf[i], surf[i + 1] - md, surf[i + 1] + md);
    }
    std::vector<float> sm = surf;
    for (size_t i = 1; i + 1 < pts.size(); i++)
      surf[i] = (sm[i - 1] + 2.0f * sm[i] + sm[i + 1]) * 0.25f;
  }

  float sea_buf = world_to_buf(sea_world);
  float lat_grade = clampf_(max_grade * 4.0f, 0.08f, 0.4f);
  float shoulder_cap = clampf_(amplitude * 0.35f, width_world, 30.0f);
  int scan_r = (int)std::ceil(wr + shoulder_cap / world_per_texel + 1.0f);

  const float INF = std::numeric_limits<float>::infinity();
  std::vector<float> best_d(w * h, INF);
  std::vector<float> best_surf(w * h, 0.0f);

  for (size_t i = 0; i < pts.size(); i++)
  {
    float cxf = pts[i].first, cyf = pts[i].second;
    float sw = surf[i];
    int x0 = std::max(0, (int)std::floor(cxf - scan_r));
    int x1 = std::min(w - 1, (int)std::ceil(cxf + scan_r));
    int y0 = std::max(0, (int)std::floor(cyf - scan_r));
    int y1 = std::min(h - 1, (int)std::ceil(cyf + scan_r));
    for (int ty = y0; ty <= y1; ty++)
    {
      for (int tx = x0; tx <= x1; tx++)
      {
        int idx = ty * w + tx;
        float ddx = tx - cxf, ddy = ty - cyf;
        float d = std::sqrt(ddx * ddx + ddy * ddy);
        if (d < best_d[idx])
        {
          best_d[idx] = d;
          best_surf[idx] = sw;
        }
      }
    }
  }

  for (int idx = 0; idx < w * h; idx++)
  {
    float dn = best_d[idx];
    if (dn == INF)
      continue;
    if (orig[idx] <= sea_buf) // only ever touch land
      continue;
    float sw = best_surf[idx];
    float ow = h_world(orig[idx]);
    float new_h;
    float m;
    if (dn <= wr)
    {
      new_h = sw; // genuinely flat road bed
      m = 1.0f;
    }
    else
    {
      float ld = (dn - wr) * world_per_texel;
      float sh_len = clampf_(std::fabs(ow - sw) / lat_grade, 0.001f, shoulder_cap);
      if (ld >= sh_len)
        continue; // beyond embankment: natural terrain
      float u = ld / sh_len;
      float blend = u * u * (3.0f - 2.0f * u); // smoothstep fillet
      new_h = lerpf_(sw, ow, blend);
      m = clampf_(1.0f - (dn - wr) / std::max(wr * 0.6f, 1.0f), 0.0f, 1.0f);
    }
    buf[idx] = world_to_buf(new_h);
    if (m > 0.0f)
    {
      int mi = idx * 2 + mask_channel;
      mask[mi] = std::max(mask[mi], m);
    }
  }
}

void TerrainBuilder::build_network(std::mt19937 &rng, int node_count,
                                   float width_world, float max_grade, int mask_channel)
{
  float min_wp_world = sea_level + 0.04f * amplitude;
  float min_wp_buf = world_to_buf(min_wp_world);
  int margin = std::max(2, (int)(std::min(w, h) * 0.08f));
  float min_sep = std::min(w, h) * 0.18f;
  float flat_thresh = lerpf_(1.2f, 0.35f, hill_avoidance);

  std::uniform_int_distribution<int> dx(margin, w - 1 - margin);
  std::uniform_int_distribution<int> dy(margin, h - 1 - margin);

  std::vector<std::pair<int, int>> wp;
  int attempts = 0;
  int max_attempts = node_count * 200;
  while ((int)wp.size() < node_count && attempts < max_attempts)
  {
    attempts++;
    int px = dx(rng);
    int py = dy(rng);
    if (buf[py * w + px] <= min_wp_buf)
      continue;
    float bar = (attempts < node_count * 120) ? flat_thresh : flat_thresh * 3.0f;
    if (local_steepness(px, py) > bar)
      continue;
    bool ok = true;
    for (auto &p : wp)
    {
      float sx = px - p.first, sy = py - p.second;
      if (std::sqrt(sx * sx + sy * sy) < min_sep)
      {
        ok = false;
        break;
      }
    }
    if (ok)
      wp.push_back({px, py});
  }
  if (wp.size() < 2)
    return;

  // Minimum spanning tree (Prim) by planar distance — one connected network,
  // no redundant loops.
  int n = (int)wp.size();
  std::vector<bool> in_tree(n, false);
  in_tree[0] = true;
  std::vector<std::pair<int, int>> edges;
  for (int e = 0; e < n - 1; e++)
  {
    float best = std::numeric_limits<float>::infinity();
    int ba = -1, bb = -1;
    for (int a = 0; a < n; a++)
    {
      if (!in_tree[a])
        continue;
      for (int b = 0; b < n; b++)
      {
        if (in_tree[b])
          continue;
        float sx = wp[a].first - wp[b].first, sy = wp[a].second - wp[b].second;
        float d = std::sqrt(sx * sx + sy * sy);
        if (d < best)
        {
          best = d;
          ba = a;
          bb = b;
        }
      }
    }
    if (bb < 0)
      break;
    in_tree[bb] = true;
    edges.push_back({ba, bb});
  }

  for (auto &e : edges)
  {
    std::vector<int> route = astar(wp[e.first].first, wp[e.first].second,
                                   wp[e.second].first, wp[e.second].second);
    if (route.size() < 2)
      continue;
    // Strip the staircase to a coarse control polygon, then Chaikin-smooth
    // it into a flowing curve (endpoints pinned to the waypoints).
    int stride = std::max(3, (int)std::lround((width_world * 0.75f) / world_per_texel));
    std::vector<std::pair<float, float>> ctrl;
    for (size_t i = 0; i < route.size(); i += stride)
      ctrl.push_back({(float)(route[i] % w), (float)(route[i] / w)});
    int last = route.back();
    if (ctrl.empty() ||
        ctrl.back().first != (float)(last % w) || ctrl.back().second != (float)(last / w))
      ctrl.push_back({(float)(last % w), (float)(last / w)});
    std::vector<std::pair<float, float>> poly = chaikin(ctrl, 3);
    for (auto &q : poly)
    {
      q.first = clampf_(q.first, 0.0f, (float)(w - 1));
      q.second = clampf_(q.second, 0.0f, (float)(h - 1));
    }
    carve_route(poly, width_world, max_grade, mask_channel);
  }
}

Dictionary TerrainBuilder::build(Array matrix, Dictionary cfg)
{
  Dictionary out;
  h = matrix.size();
  if (h == 0)
    return out;
  Array first_row = matrix[0];
  w = first_row.size();
  if (w == 0)
    return out;

  amplitude = cfg_f(cfg, "amplitude", 100.0f);
  sea_level = cfg_f(cfg, "sea_level", 0.0f);
  terrain_size = cfg_f(cfg, "terrain_size", 1000.0f);
  hill_avoidance = clampf_(cfg_f(cfg, "hill_avoidance", 0.7f), 0.0f, 1.0f);
  bool paths_enabled = cfg_b(cfg, "paths_enabled", false);
  bool roads_enabled = cfg_b(cfg, "roads_enabled", false);

  int lowest_i = 999999, highest_i = -999999;
  buf.assign((size_t)w * h, 0.0f);
  for (int y = 0; y < h; y++)
  {
    Array row = matrix[y];
    for (int x = 0; x < w; x++)
    {
      int cell = (int)row[x];
      buf[y * w + x] = (float)cell;
      lowest_i = std::min(lowest_i, cell);
      highest_i = std::max(highest_i, cell);
    }
  }
  lowest = (float)lowest_i;
  range = (float)(highest_i - lowest_i);
  if (range == 0.0f)
    range = 1.0f;
  world_per_texel = terrain_size / (float)w;
  world_per_buf = amplitude / range;

  box_blur_2x();

  mask.assign((size_t)w * h * 2, 0.0f);

  if (paths_enabled || roads_enabled)
  {
    orig = buf; // natural reference, captured before any carve
    g_cost.assign((size_t)w * h, 0.0f);
    came.assign((size_t)w * h, -1);
    closed.assign((size_t)w * h, 0);

    unsigned int seed = (unsigned int)cfg_i(cfg, "seed", 0);
    std::mt19937 rng(seed);
    if (paths_enabled)
      build_network(rng, std::max(2, cfg_i(cfg, "path_node_count", 7)),
                    std::max(0.5f, cfg_f(cfg, "path_width", 4.0f)),
                    clampf_(cfg_f(cfg, "path_max_grade", 0.14f), 0.01f, 1.0f), 0);
    if (roads_enabled)
      build_network(rng, std::max(2, cfg_i(cfg, "road_node_count", 5)),
                    std::max(0.5f, cfg_f(cfg, "road_width", 11.0f)),
                    clampf_(cfg_f(cfg, "road_max_grade", 0.08f), 0.01f, 1.0f), 1);
  }

  Ref<Image> himg = Image::create_empty(w, h, false, Image::FORMAT_RF);
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
      himg->set_pixel(x, y, Color((buf[y * w + x] - lowest) / range, 0.0f, 0.0f));
  himg->generate_mipmaps();

  Ref<Image> mimg = Image::create_empty(w, h, false, Image::FORMAT_RGF);
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++)
    {
      int i = (y * w + x) * 2;
      mimg->set_pixel(x, y, Color(mask[i], mask[i + 1], 0.0f));
    }
  mimg->generate_mipmaps();

  out["height"] = ImageTexture::create_from_image(himg);
  out["mask"] = ImageTexture::create_from_image(mimg);

  // Free the big scratch buffers; the textures are what callers keep.
  buf.clear();
  buf.shrink_to_fit();
  orig.clear();
  orig.shrink_to_fit();
  mask.clear();
  mask.shrink_to_fit();
  g_cost.clear();
  g_cost.shrink_to_fit();
  came.clear();
  came.shrink_to_fit();
  closed.clear();
  closed.shrink_to_fit();
  return out;
}
