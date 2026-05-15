@tool
class_name WaterPlane extends Node3D

# A transparent water surface positioned at DrawMatrix3D.sea_level. The shader
# samples the heightmap to fade color + alpha with seafloor depth and draw
# shoreline foam, so this plane does not need to match land topology itself —
# one big subdivided quad is enough.

@export var draw_matrix_3d: NodePath
# Subdivision count per side — vertex wave displacement needs enough density.
@export var subdivisions: int = 128
# Small margin beyond terrain extent so water extends past the map edge.
@export var size_margin: float = 0.0

var _mesh_instance: MeshInstance3D

func _ready():
	var dm := _get_draw_matrix()
	if dm != null and not dm.terrain_generated.is_connected(_rebuild):
		dm.terrain_generated.connect(_rebuild)
	_rebuild()

func _rebuild():
	for child in get_children():
		child.queue_free()
	_mesh_instance = null

	var dm := _get_draw_matrix()
	if dm == null:
		return
	if dm.water_material == null:
		return

	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Y
	var side := dm.terrain_size + size_margin * 2.0
	plane.size = Vector2(side, side)
	plane.subdivide_width = subdivisions
	plane.subdivide_depth = subdivisions
	plane.material = dm.water_material

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = plane
	_mesh_instance.position = Vector3(0.0, dm.sea_level, 0.0)
	# Water surface is fully sky-facing; it doesn't need to cast shadows onto
	# land and skipping helps with the transparent-surface sort cost.
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# PlaneMesh's default AABB is flat in Y. When viewed edge-on the culler
	# treats the zero-thickness box as outside the frustum and drops the
	# whole plane, so we inflate the AABB vertically by the terrain
	# amplitude — enough slack that no camera angle collapses it.
	var half := side * 0.5
	var y_pad: float = max(dm.amplitude, 16.0)
	_mesh_instance.custom_aabb = AABB(
		Vector3(-half, -y_pad, -half),
		Vector3(side, y_pad * 2.0, side)
	)
	add_child(_mesh_instance)

# Call after DrawMatrix3D finishes generating (height texture, sea_level, and
# terrain_size are all known by then).
func refresh():
	_rebuild()

func _get_draw_matrix() -> DrawMatrix3D:
	if draw_matrix_3d.is_empty():
		return null
	var node := get_node_or_null(draw_matrix_3d)
	if node == null:
		return null
	return node as DrawMatrix3D
