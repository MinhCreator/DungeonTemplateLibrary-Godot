@tool
class_name DrawMatrix3D extends Node3D

# Emitted after draw_terrain() finishes configuring both materials with a
# fresh heightmap. Consumers (e.g. WaterPlane) rebuild off this instead of
# every scene's per-terrain script forwarding the matrix manually.
signal terrain_generated

@export var amplitude: float = 10.0: set = _set_amplitude
@export var sea_level: float = 10.0: set = _set_sea_level
@export var beach_level: float = 10.0: set = _set_beach_level
@export var grass_level: float = 10.0: set = _set_grass_level
@export var cliff_level: float = 10.0: set = _set_cliff_level
@export var snow_level: float = 10.0: set = _set_snow_level
@export var terrain_size: float = 500.0: set = _set_terrain_size
@export var max_subdivisions: int = 256

@export_group("Water Animation")
@export var water_wave_speed: float = 0.35: set = _set_water_wave_speed
@export var water_wave_scale: float = 80.0: set = _set_water_wave_scale
@export var water_wave_strength: float = 0.2: set = _set_water_wave_strength

@export_group("Water Edge")
@export var water_edge_color: Color = Color(0.85, 0.95, 1.0): set = _set_water_edge_color
@export var water_edge_width: float = 5.0: set = _set_water_edge_width
@export var water_edge_intensity: float = 0.9: set = _set_water_edge_intensity

var center_height: float = 0.0
var terrain_material := ShaderMaterial.new()
var water_material := ShaderMaterial.new()
var terrain_shader: Shader = load("res://assets/shaders/terrain.gdshader")
var water_shader: Shader = load("res://assets/shaders/water.gdshader")
var default_colors: Array[Color] = [
	Color.DARK_BLUE,
	Color("#e5d9c2"),
	Color("#725428"),
	Color("#b5ba61"),
	Color("#7c8d4c"),
	Color.DARK_OLIVE_GREEN
]

func _ready():
	terrain_material.shader = terrain_shader
	water_material.shader = water_shader

func _set_amplitude(new_value: float):
	amplitude = new_value
	terrain_material.set_shader_parameter("amplitude", new_value)
	water_material.set_shader_parameter("amplitude", new_value)

func _set_sea_level(new_value: float):
	sea_level = new_value
	terrain_material.set_shader_parameter("sea_level", new_value)
	water_material.set_shader_parameter("sea_level", new_value)

func _set_beach_level(new_value: float):
	beach_level = new_value
	terrain_material.set_shader_parameter("beach_level", new_value)

func _set_grass_level(new_value: float):
	grass_level = new_value
	terrain_material.set_shader_parameter("grass_level", new_value)

func _set_cliff_level(new_value: float):
	cliff_level = new_value
	terrain_material.set_shader_parameter("cliff_level", new_value)

func _set_snow_level(new_value: float):
	snow_level = new_value
	terrain_material.set_shader_parameter("snow_level", new_value)

func _set_terrain_size(new_value: float):
	terrain_size = new_value
	water_material.set_shader_parameter("terrain_size", new_value)

func _set_water_wave_speed(new_value: float):
	water_wave_speed = new_value
	water_material.set_shader_parameter("wave_speed", new_value)

func _set_water_wave_scale(new_value: float):
	water_wave_scale = new_value
	water_material.set_shader_parameter("wave_scale", new_value)

func _set_water_wave_strength(new_value: float):
	water_wave_strength = new_value
	water_material.set_shader_parameter("wave_strength", new_value)

func _set_water_edge_color(new_value: Color):
	water_edge_color = new_value
	water_material.set_shader_parameter("edge_color", new_value)

func _set_water_edge_width(new_value: float):
	water_edge_width = new_value
	water_material.set_shader_parameter("edge_width", new_value)

func _set_water_edge_intensity(new_value: float):
	water_edge_intensity = new_value
	water_material.set_shader_parameter("edge_intensity", new_value)

func draw_heightmap(matrix: Array) -> ImageTexture:
	var height: int = matrix.size()
	var width: int = matrix[0].size()

	var image: Image = Image.create_empty(width, height, false, Image.FORMAT_RF)

	var highest_value: int = -9999
	var lowest_value: int = 9999

	var raw: PackedFloat32Array = PackedFloat32Array()
	raw.resize(width * height)
	for y in range(height):
		for x in range(width):
			var cell: int = matrix[y][x]
			raw[y * width + x] = float(cell)
			if cell < lowest_value:
				lowest_value = cell
			if cell > highest_value:
				highest_value = cell

	var range_f: float = float(highest_value - lowest_value)
	if range_f == 0.0:
		range_f = 1.0

	# Two 3x3 box blur passes (~5x5 Gaussian) smooth DTL's integer step
	# quantization — one pass isn't enough for dense maps with many octaves.
	var buf_a: PackedFloat32Array = raw
	var buf_b: PackedFloat32Array = PackedFloat32Array()
	buf_b.resize(width * height)
	for _pass in range(2):
		for y in range(height):
			for x in range(width):
				var sum: float = 0.0
				var count: int = 0
				for dy in range(-1, 2):
					var ny: int = y + dy
					if ny < 0 or ny >= height:
						continue
					for dx in range(-1, 2):
						var nx: int = x + dx
						if nx < 0 or nx >= width:
							continue
						sum += buf_a[ny * width + nx]
						count += 1
				buf_b[y * width + x] = sum / float(count)
		var tmp: PackedFloat32Array = buf_a
		buf_a = buf_b
		buf_b = tmp

	for y in range(height):
		for x in range(width):
			var normalized: float = (buf_a[y * width + x] - float(lowest_value)) / range_f
			image.set_pixel(x, y, Color(normalized, 0.0, 0.0))

	var cx := width / 2
	var cy := height / 2
	center_height = image.get_pixel(cx, cy).r * amplitude

	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func draw_terrain(matrix: Array):
	for child in get_children():
		child.queue_free()

	terrain_material.shader = terrain_shader
	water_material.shader = water_shader
	var height_tex := draw_heightmap(matrix)
	var tex_size := height_tex.get_size()
	terrain_material.set_shader_parameter("amplitude", amplitude)
	terrain_material.set_shader_parameter("height_texture", height_tex)
	terrain_material.set_shader_parameter("texel_size", Vector2(1.0 / tex_size.x, 1.0 / tex_size.y))

	# Water material shares the heightmap so it can sample seafloor depth
	# per-fragment for color gradient, alpha, and shoreline foam.
	water_material.set_shader_parameter("amplitude", amplitude)
	water_material.set_shader_parameter("sea_level", sea_level)
	water_material.set_shader_parameter("terrain_size", terrain_size)
	water_material.set_shader_parameter("height_texture", height_tex)

	var subs: int = mini(maxi(int(tex_size.x), int(tex_size.y)), max_subdivisions)
	var quadmesh := PlaneMesh.new()
	quadmesh.orientation = PlaneMesh.FACE_Y
	quadmesh.size = Vector2(terrain_size, terrain_size)
	quadmesh.subdivide_width = subs
	quadmesh.subdivide_depth = subs
	quadmesh.material = terrain_material

	var mesh := MeshInstance3D.new()
	mesh.mesh = quadmesh
	add_child(mesh)

	terrain_generated.emit()
