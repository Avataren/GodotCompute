extends Node3D

@export var world_environment_path : NodePath
@export var sun_light_path        : NodePath      # your DirectionalLight3D

var _ray : RayMarcher
var _sun : DirectionalLight3D

func _ready() -> void:
	_sun = get_node(sun_light_path)
	var env : WorldEnvironment = get_node(world_environment_path)
	# grab the first RayMarcher in the Environment effect list
	for eff in env.compositor.compositor_effects:
		if eff is RayMarcher:
			_ray = eff
			break

func _process(_delta: float) -> void:
	if _ray and _sun:
		# light travels along -Z, we need the opposite
		var dir = -_sun.global_transform.basis.z.normalized()
		_ray.set_sun_direction(dir)
