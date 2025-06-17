# fill_view.gd
# Attach this script to a Sprite3D node that is a child of a Camera3D.
# It will automatically resize the sprite to perfectly fill the camera's view.
@tool
extends Sprite3D

## The camera that this sprite will fill. If not set, it will try to use its parent.
@export var camera_path: NodePath

var camera: Camera3D
var last_viewport_size: Vector2

func _enter_tree() -> void:
	# Make sure we keep getting _process() every frame,
	# even while the scene is just open in the editor.
	process_mode = Node.PROCESS_MODE_ALWAYS 

func _ready() -> void:
	# Wait until the node tree is ready to safely get nodes.
	await get_tree().process_frame
	
	# Get the camera node from the exported path.
	if camera_path:
		camera = get_node_or_null(camera_path)
	
	# If no camera was assigned, try to get the parent node.
	if not camera:
		camera = get_parent() as Camera3D

	# Initial resize.
	update_sprite_size()
	
	# Store the current viewport size to detect changes (like window resizing).
	if is_instance_valid(get_viewport()):
		last_viewport_size = get_viewport().get_visible_rect().size


func _process(_delta: float) -> void:
	# In the editor or game, continuously check if the viewport size has changed.
	if not is_instance_valid(get_viewport()):
		return
		
	var current_viewport_size = get_viewport().get_visible_rect().size
	if current_viewport_size != last_viewport_size:
		update_sprite_size()
		last_viewport_size = current_viewport_size
		
	# The @tool annotation makes this run in the editor.
	# The following is needed for live updates in the editor when you move the sprite.
	if Engine.is_editor_hint():
		update_sprite_size()

func update_sprite_size() -> void:
	# Ensure we have a valid camera and a texture to work with.
	if not is_instance_valid(camera):
		printerr("Fill View Sprite: Camera not found or is invalid.")
		return
	if not texture:
		# for some reason, texture is never set while in editor!
		# print ("no texture")
		
		# Can't calculate scale without a texture's base size.
		# A Sprite3D without a texture is invisible anyway.
		return

	var view_height: float
	var view_width: float

	# The distance is the Sprite3D's local Z position relative to the camera.
	# We use abs() because the sprite is typically placed at a negative Z value.
	var distance = abs(position.z)
	if distance < camera.near:
		# If the sprite is closer than the camera's near clip plane, it won't be visible.
		# We can't calculate a meaningful size, so we hide it.
		visible = false
		return
	else:
		visible = true

	var viewport_aspect = get_viewport().get_visible_rect().size.aspect()

	# --- Calculate the view size at the given distance ---
	if camera.projection == Camera3D.ProjectionType.PROJECTION_PERSPECTIVE:
		# For a perspective camera, we use trigonometry with the FOV.
		# The FOV is the vertical angle, so we calculate height first.
		# tan(angle) = opposite / adjacent
		# tan(fov/2) = (view_height/2) / distance
		# view_height = 2 * distance * tan(fov/2)
		var fov_rad = deg_to_rad(camera.fov)
		view_height = 2.0 * distance * tan(fov_rad / 2.0)
		view_width = view_height * viewport_aspect
		
	elif camera.projection == Camera3D.ProjectionType.PROJECTION_ORTHOGONAL:
		# For an orthographic camera, it's simpler. The 'size' is the vertical height.
		view_height = camera.size
		view_width = view_height * viewport_aspect

	# --- Apply the size to the sprite ---
	# A Sprite3D's size in world units is its texture_size * pixel_size.
	# We want to find the scale needed to match our calculated view_width and view_height.
	# Required Scale = Target Size / Base Size
	var base_width = texture.get_width() * pixel_size
	var base_height = texture.get_height() * pixel_size
	
	if base_width == 0 or base_height == 0:
		# Avoid division by zero if the texture or pixel_size is invalid.
		return

	# Set the scale of the Sprite3D.
	scale.x = view_width / base_width
	scale.y = view_height / base_height
