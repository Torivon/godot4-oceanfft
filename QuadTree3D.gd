extends Node3D
class_name QuadTree3D


@export_range(0, 1000000, 1) var lod_level := 2
@export_range(1.0, 65535.0) var quad_size := 1024.0
@export_range(1.0, 8192.0) var mesh_size := 256.0
@export_range(0.0, 1.0) var morph_range := 0.3;
@export_range(0.0, 0.001) var planetary_curve_strength := 0.000001:
	set(new_planetary_curve_strength):
		planetary_curve_strength = new_planetary_curve_strength
		material.set_shader_parameter("planetary_curve_strength", planetary_curve_strength)
@export_range(0.0, 32000.0, 1.0) var mesh_resolution := 256.0
@export var ranges:Array[float] = [512.0, 1024.0, 2048.0]
@export_node_path(Camera3D) var camera


var pause_cull := false
var cull_box:AABB:
	get:
		return AABB(
				global_position + _visibility_detector.aabb.position,
				_visibility_detector.aabb.size)
	set(new_aabb):
		_visibility_detector.aabb = new_aabb

var mesh_instance_high_lod:MeshInstance3D
var mesh_instance_low_lod:MeshInstance3D
var material:ShaderMaterial:
	get:
		return mesh_instance_high_lod.material_override
	set(new_material):
		mesh_instance_high_lod.material_override = new_material
		mesh_instance_low_lod.material_override = new_material


var _subquads:Array[QuadTree3D] = []
var _camera:Camera3D


@onready var _visibility_detector:VisibleOnScreenNotifier3D = $VisibleOnScreenNotifier3D


func _ready() -> void:
	## For some reason this doesn't work as a preload()? I'm probably doing
	## something wrong... It's not enough of a problem to care right now.
	var quad = load("res://QuadTree3D.tscn")
	var offset_length:float = quad_size * 0.25
	
	mesh_instance_high_lod = $MeshHighLOD
	mesh_instance_high_lod.mesh = PlaneMesh.new()
	mesh_instance_high_lod.mesh.size = Vector2.ONE * quad_size
	mesh_instance_high_lod.mesh.subdivide_depth = mesh_resolution
	mesh_instance_high_lod.mesh.subdivide_width = mesh_resolution
	
	mesh_instance_high_lod.set_instance_shader_parameter("vertex_resolution", mesh_resolution)
	mesh_instance_high_lod.set_instance_shader_parameter("patch_size", quad_size)
	mesh_instance_high_lod.set_instance_shader_parameter("min_lod_morph_distance", get_min_lod_morph_distance(lod_level))
	mesh_instance_high_lod.set_instance_shader_parameter("max_lod_morph_distance", ranges[lod_level] * 1.5)
	
	mesh_instance_low_lod = $MeshLowLOD
	mesh_instance_low_lod.mesh = PlaneMesh.new()
	mesh_instance_low_lod.mesh.size = Vector2.ONE * quad_size
	mesh_instance_low_lod.mesh.subdivide_depth = mesh_resolution * 0.5 - 1
	mesh_instance_low_lod.mesh.subdivide_width = mesh_resolution * 0.5 - 1
	
	mesh_instance_low_lod.set_instance_shader_parameter("vertex_resolution", mesh_resolution * 0.5)
	mesh_instance_low_lod.set_instance_shader_parameter("patch_size", quad_size)
	mesh_instance_low_lod.set_instance_shader_parameter("min_lod_morph_distance", get_min_lod_morph_distance(lod_level + 1) * 1.75)
	mesh_instance_low_lod.set_instance_shader_parameter("max_lod_morph_distance", ranges[lod_level + 1] * 1.8)
	
	## If a NodePath to a Camera3D has been specified in the export, grab it.
	## This is the camera that culling will be based on.
	if camera != null:
		_camera = get_node(camera)
	
	## Initialized with size only, global position is added in the setter
	cull_box = AABB(Vector3(-quad_size * 0.5, quad_size * -0.5, -quad_size * 0.5),
			Vector3(quad_size * 1.0, quad_size, quad_size * 1.0))
	
	## If this is not the most detailed LOD level, initialize more detailed
	## children.
	if lod_level > 0:
		for offset in [Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, -1)]:
			var new_quad = quad.instantiate()
			new_quad.lod_level = lod_level - 1
			new_quad.quad_size = quad_size * 0.5
			new_quad.ranges = ranges
			new_quad.process_mode = PROCESS_MODE_DISABLED
			new_quad.position = offset * offset_length
			new_quad.mesh_resolution = mesh_resolution
			new_quad.morph_range = morph_range
			
			$SubQuads.add_child(new_quad)
			_subquads.append(new_quad)


## Process mode is set to PROCESS_MODE_DISABLED for subquads, so only the root
## quad will run _process().
func _process(_delta:float) -> void:
	if not pause_cull:
		var offset:Vector3 = _camera.global_position.snapped(Vector3(512.0, 0.0, 512.0))
		var frustrum_override := false
		offset.y = 0.0
		if not offset.is_equal_approx(global_position):
			global_position = offset
			frustrum_override = true
		
		reset_visibility()
		lod_select(_camera.global_position, frustrum_override)


## Select which meshes will be displayed at which LOD level. A return value of
## true marks the node as handled, and a value of false indicates the parent
## node must handle it.
## cam_pos is the camera/player position in global coordinates.
## frustrum_override, if true, forces all quads to be considered within the
## camera frustrum. If this is false, this will be determined by a
## VisibleOnScreenNotifier3D for each quad.
func lod_select(cam_pos:Vector3, frustrum_override:bool) -> bool:
	## Beginning at the root node of lowest LOD, and working towards the most
	## detailed LOD 0.
	
	if not within_sphere(cam_pos, ranges[lod_level]):
		## This quad is not within range of the selected LOD level, the parent
		## will need to display this at a lower detailed LOD. Return false to
		## mark the area as not handled.
		return false
	
	if not (_visibility_detector.is_on_screen() or frustrum_override):
		## This quad is not on screen. Do not make it visible, and return true
		## to mark the area as handled.
		return true
	
	if lod_level == 0:
		## Within range of selected LOD level, and at highest detailed LOD,
		## there are no more detailed children to render this. Make this quad
		## visible. Return true to mark the area handled.
		mesh_instance_high_lod.visible = true
		return true
	
	else:
		## Within range of selected LOD level, but there are more detailed
		## children that may be able to display this. Check if any are within
		## their LOD range.
		if not within_sphere(cam_pos, ranges[lod_level - 1]):
			## No children are within range of their LOD levels, make this quad
			## visible to handle the area.
			mesh_instance_high_lod.visible = true
		
		else:
			## At least one more detailed children is within LOD range. Recurse
			## through them and select them if appropriate.
			for subquad in _subquads:
				if not subquad.lod_select(cam_pos, frustrum_override):
					## If a child node is out of its LOD range, we need to force
					## it to display at a lower detailed LOD.
					subquad.mesh_instance_low_lod.visible = true
		
		## The area has been handled.
		return true


## Reset all quads to invisible.
func reset_visibility() -> void:
	if mesh_instance_high_lod.visible or mesh_instance_low_lod.visible:
		## If this quad is visible, no children should be visible.
		mesh_instance_high_lod.visible = false
		mesh_instance_low_lod.visible = false
	
	else:
		## If this quad is not visible, there are likely children displaying it.
		for subquad in _subquads:
			subquad.reset_visibility()


## Returns true if this quads cull_box AABB intersects with a sphere with the
## specified radius and center point.
func within_sphere(center:Vector3, radius:float) -> bool:
	var vector:Vector3 = (cull_box.abs().get_center() - center).normalized()
	
	if cull_box.intersects_segment(center, center + (vector * radius)):
		return true
	
	return false


func get_min_lod_morph_distance(lod:int) -> float:
	if lod == 0:
		return ranges[lod] * (1.0 - morph_range)
	
	return (ranges[lod] - ranges[lod - 1]) * (1.0 - morph_range) + ranges[lod - 1]
