@tool
class_name RayMarcher extends CompositorEffect

const LOCAL_WORKGROUP_X: int = 16
const LOCAL_WORKGROUP_Y: int = 16

var rd : RenderingDevice
var shader : RID
var pipeline : RID

func _init():
	RenderingServer.call_on_render_thread(initialize_compute_shader)
	
func _notification(what: int):
	if what == NOTIFICATION_PREDELETE:
		if shader.is_valid():RenderingServer.free_rid(shader);
		if pipeline.is_valid(): RenderingServer.free_rid(pipeline)
			
func initialize_compute_shader():
	rd = RenderingServer.get_rendering_device()
	if not rd: return
	load_shader()
	
func clean_up():
	if pipeline.is_valid(): rd.free_rid(pipeline)
	if shader.is_valid(): rd.free_rid(shader)
	
func load_shader():
	clean_up()
	var glsl_file : RDShaderFile = load("res://shaders/compositor/RayMarcher.glsl")
	shader = rd.shader_create_from_spirv(glsl_file.get_spirv())
	pipeline = rd.compute_pipeline_create(shader)	
	
func _render_callback(_effect_callback_type: int, render_data: RenderData) -> void:
	if not rd: return
	if not shader.is_valid(): load_shader()
	
	var scene_buffers : RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data : RenderSceneData = render_data.get_render_scene_data()
	if not scene_buffers: return
	
	var size: Vector2i = scene_buffers.get_internal_size()
	if (size.x == 0 || size.y == 0): return
	
	var x_groups : int = ceili(size.x / float(LOCAL_WORKGROUP_X))
	var y_groups : int = ceili(size.y / float(LOCAL_WORKGROUP_Y))
	
	var cam_xform : Transform3D = scene_data.get_cam_transform()
	var inv_proj_mat : Projection = scene_data.get_cam_projection().inverse()
	
	for view in scene_buffers.get_view_count():
		var proj : Projection = scene_data.get_view_projection(view)
		var fov_deg : float  = proj.get_fov()
		var push_constants := _fill_push_constants(cam_xform, fov_deg, size, inv_proj_mat[2].w, inv_proj_mat[3].w)
		var screen_tex:RID = scene_buffers.get_color_layer(view)
		var depth_tex:RID = scene_buffers.get_depth_layer(view)
		
		var uniform :RDUniform = RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		uniform.binding = 0
		uniform.add_id(screen_tex)
		
		var image_uniform_set : RID
		#if (Engine.is_editor_hint()):
			#image_uniform_set = rd.uniform_set_create([uniform], shader, 0)
		#else:
		image_uniform_set = UniformSetCacheRD.get_cache(shader, 0, [uniform])
		
		var sampler_state : RDSamplerState = RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		var sampler : RID = rd.sampler_create(sampler_state)
		
		uniform = RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = 0
		uniform.add_id(sampler)
		uniform.add_id(depth_tex)
		
		var depth_uniform_set:RID = UniformSetCacheRD.get_cache(shader, 1, [uniform])
		
		var compute_list :int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, image_uniform_set, 0)
		rd.compute_list_bind_uniform_set(compute_list, depth_uniform_set, 1)
		rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
		rd.compute_list_dispatch(compute_list, x_groups, y_groups,1)
		rd.compute_list_end()
	
func _fill_push_constants(cam_xform: Transform3D, fov: float,  screen_size: Vector2i, inv_proj2w: float, inv_proj3w: float) -> PackedByteArray:
	# Get the camera's full transform.

	var floats = PackedFloat32Array()
	floats.resize(24)
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
	floats[16] = screen_size.x
	floats[17] = screen_size.y
	# --- 3. Params.fov_rad (float) - 4 bytes (Float 18) ---
	floats[18] = deg_to_rad(fov)
	floats[19] = inv_proj2w
	floats[20] = inv_proj3w
	floats[21] = 0.0
	floats[22] = 0.0
	floats[23] = 0.0
	

	return floats.to_byte_array()
