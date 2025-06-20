@tool
extends Node3D

@export_node_path("Sprite3D") var display_sprite_path
@onready var display_sprite := get_node(display_sprite_path) as Sprite3D

# We need a reference to the camera to get its transform
@export_node_path("Camera3D") var camera_path
@onready var camera := get_node(camera_path) as Camera3D

const LOCAL_SIZE := 16

var rd: RenderingDevice
var shader_rd: RID
var pipeline: RID
var output_texture_set_rd: RID
var tex: RID
var img_tex: Texture2DRD
var num_workgroups_x: int
var num_workgroups_y: int
var current_viewport_size := Vector2i.ZERO

func _ready():
	get_viewport().connect("size_changed", Callable(self, "_on_viewport_size_changed"))
	RenderingServer.call_on_render_thread.call_deferred(Callable(self, "_initialize_compute_shader"))
	call_deferred("_set_external_assets")

func _on_viewport_size_changed():
	RenderingServer.call_on_render_thread.call_deferred(Callable(self, "_initialize_compute_shader"))
	call_deferred("_set_external_assets")

func _initialize_compute_shader():
	_free_resources()
	if get_viewport() == null:
		return;

	rd = RenderingServer.get_rendering_device()
	var new_viewport_size = get_viewport().get_visible_rect().size
	if new_viewport_size.x <= 0 or new_viewport_size.y <= 0:
		return
	current_viewport_size = new_viewport_size

	var shader_file:= load("res://shaders/compute/test_shader.glsl")
	shader_rd = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not shader_rd.is_valid():
		push_error("Invalid SPIR-V from shader file!")
		return

	pipeline = rd.compute_pipeline_create(shader_rd)
	if not rd.compute_pipeline_is_valid(pipeline):
		push_error("Compute pipeline is invalid! Did you forget #[compute]?")
		return

	_create_shader_assets();

	if not RenderingServer.is_connected("frame_pre_draw", Callable(self, "_run_compute")):
		RenderingServer.connect("frame_pre_draw", Callable(self, "_run_compute"))

func _create_shader_assets():
	var fmt = RDTextureFormat.new()
	fmt.width = current_viewport_size.x
	fmt.height = current_viewport_size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	tex = rd.texture_create(fmt, RDTextureView.new())

	var uni = RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uni.binding = 0
	uni.add_id(tex)
	output_texture_set_rd = rd.uniform_set_create([uni], shader_rd, 0)

	img_tex = Texture2DRD.new()
	img_tex.texture_rd_rid = tex
	
	num_workgroups_x = int(ceil(current_viewport_size.x / float(LOCAL_SIZE)))
	num_workgroups_y = int(ceil(current_viewport_size.y / float(LOCAL_SIZE)))
	
func _set_external_assets():
	print ("setting external assets")
	display_sprite.texture = img_tex

func _run_compute():
	if not rd or not pipeline.is_valid() or not output_texture_set_rd.is_valid() or current_viewport_size == Vector2i.ZERO:
		return
	RenderingServer.call_on_render_thread.call_deferred(Callable(self, "_dispatch_compute"))

func _dispatch_compute():
	var push_constant = _fill_push_constants()
	
	var compute_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, output_texture_set_rd, 0)
	rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
	rd.compute_list_dispatch(compute_list, num_workgroups_x, num_workgroups_y, 1)
	rd.compute_list_end()
	
	
# This function manually serializes the push constants into a PackedByteArray
# to match the std430 layout defined in the compute shader.
func _fill_push_constants() -> PackedByteArray:
	# Get the camera's full transform.
	var cam_xform := camera.global_transform
	var floats = PackedFloat32Array()
	floats.resize(20)
	# Column 0 (Basis X vector)
	floats[0] = cam_xform.basis.x.x
	floats[1] = cam_xform.basis.x.y
	floats[2] = cam_xform.basis.x.z
	floats[3] = 0.0
	# Column 1 (Basis Y vector)
	floats[4] = cam_xform.basis.y.x
	floats[5] = cam_xform.basis.y.y
	floats[6] = cam_xform.basis.y.z
	floats[7] = 0.0
	# Column 2 (Basis Z vector)
	floats[8] = cam_xform.basis.z.x
	floats[9] = cam_xform.basis.z.y
	floats[10] = cam_xform.basis.z.z
	floats[11] = 0.0
	# Column 3 (Origin/Translation vector)
	floats[12] = cam_xform.origin.x
	floats[13] = cam_xform.origin.y
	floats[14] = cam_xform.origin.z
	floats[15] = 1.0
	# --- 2. Params.texture_size (vec2) - 8 bytes (Floats 16-17) ---
	floats[16] = current_viewport_size.x
	floats[17] = current_viewport_size.y
	# --- 3. Params.fov_rad (float) - 4 bytes (Float 18) ---
	floats[18] = deg_to_rad(camera.fov)
	floats[19] = 0.0 #padding

	return floats.to_byte_array()

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if RenderingServer && RenderingServer.is_connected("frame_pre_draw", Callable(self, "_run_compute")):
			RenderingServer.disconnect("frame_pre_draw", Callable(self, "_run_compute"))
		if get_viewport() && get_viewport().is_connected("size_changed", Callable(self, "_on_viewport_size_changed")):
			get_viewport().disconnect("size_changed", Callable(self, "_on_viewport_size_changed"))
		RenderingServer.call_on_render_thread(Callable(self, "_free_resources"))

func _free_resources():
	if rd:
		if tex.is_valid() and rd.texture_is_valid(tex):
			rd.free_rid(tex)
		if output_texture_set_rd.is_valid() and rd.uniform_set_is_valid(output_texture_set_rd):
			rd.free_rid(output_texture_set_rd)
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader_rd.is_valid():
			rd.free_rid(shader_rd)
	tex = RID()
	output_texture_set_rd = RID()
	pipeline = RID()
	shader_rd = RID()
