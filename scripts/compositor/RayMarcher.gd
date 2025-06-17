@tool
class_name RayMarcher extends CompositorEffect

const LOCAL_WORKGROUP_X: int = 16
const LOCAL_WORKGROUP_Y: int = 16

var rd : RenderingDevice
var shader : RID
var pipeline : RID

var noise_3d : Texture3D = null
		
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
	
	noise_3d = ResourceLoader.load("res://shaders/compositor/cloud_noise.tres")
	
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
	if not noise_3d:
		printerr("RayMarcher: noise_3d (Texture3D) is not assigned in the Inspector!")
		return
	var noise_texture_rid : RID = noise_3d.get_rid() # Get the RID once
	if not noise_texture_rid.is_valid():
		printerr("RayMarcher: noise_3d.get_rid() returned an invalid RID. The Texture3D might be malformed or not properly loaded.")
		return
	if not shader.is_valid(): load_shader()
	
	var scene_buffers : RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data : RenderSceneData = render_data.get_render_scene_data()
	if not scene_buffers: return
	
	var size: Vector2i = scene_buffers.get_internal_size()
	if (size.x == 0 || size.y == 0): return
	
	var x_groups : int = ceili(size.x / float(LOCAL_WORKGROUP_X))
	var y_groups : int = ceili(size.y / float(LOCAL_WORKGROUP_Y))
	
	#var cam_xform : Transform3D = scene_data.get_cam_transform()
	var view_matrix : Transform3D = scene_data.get_cam_transform()
	var inv_view_matrix : Transform3D = view_matrix.affine_inverse()
	var inv_proj_mat : Projection = scene_data.get_cam_projection().inverse()
	
	for view in scene_buffers.get_view_count():
		var proj : Projection = scene_data.get_view_projection(view)
		var hfov_deg : float = proj.get_fov()                    # horizontal
		var aspect    = float(size.x) / float(size.y)
		var vfov_rad  = 2.0 * atan(tan(deg_to_rad(hfov_deg)*0.5) / aspect)		
		
		var push_constants := _fill_push_constants(view_matrix, vfov_rad, size, inv_proj_mat[2].w, inv_proj_mat[3].w)
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
		
		var sampler_state := RDSamplerState.new()
		sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR

		#-- depth sampler --------------------------------------------------------
		var depth_sampler : RID = rd.sampler_create(sampler_state)

		var u_depth := RDUniform.new()
		u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_depth.binding = 0
		u_depth.add_id(depth_sampler)
		u_depth.add_id(depth_tex)

		#-- noise sampler --------------------------------------------------------
		var noise_sampler_state := RDSamplerState.new()
		noise_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		noise_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
		noise_sampler_state.repeat_u = RenderingDevice.SamplerRepeatMode.SAMPLER_REPEAT_MODE_REPEAT
		noise_sampler_state.repeat_v = RenderingDevice.SamplerRepeatMode.SAMPLER_REPEAT_MODE_REPEAT
		noise_sampler_state.repeat_w = RenderingDevice.SamplerRepeatMode.SAMPLER_REPEAT_MODE_REPEAT
		var noise_sampler : RID = rd.sampler_create(noise_sampler_state)

		var u_noise := RDUniform.new()
		u_noise.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		u_noise.binding = 0
		u_noise.add_id(noise_sampler)
		u_noise.add_id(RenderingServer.texture_get_rd_texture(noise_texture_rid))

		#-- one uniform-set, two bindings (0 = depth, 1 = noise) -----------------
		var depth_uniform_set : RID = UniformSetCacheRD.get_cache(shader, 1, [u_depth])
		var noise_uniform_set : RID = UniformSetCacheRD.get_cache(shader, 2, [u_noise])
		
		var compute_list :int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, image_uniform_set, 0)
		rd.compute_list_bind_uniform_set(compute_list, depth_uniform_set, 1)
		rd.compute_list_bind_uniform_set(compute_list, noise_uniform_set, 2)
		rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
		rd.compute_list_dispatch(compute_list, x_groups, y_groups,1)
		rd.compute_list_end()
	
func _fill_push_constants(cam_xform: Transform3D, fov_deg: float, screen: Vector2i, inv2w: float, inv3w: float) -> PackedByteArray:
	var sun_dir  : Vector3 = Vector3(0.6,0.8,-0.5) 
	var cloud_base  : float = 1200.0                
	var cloud_top   : float = 2000.0

	var f = PackedFloat32Array()
	f.resize(28)                                    # 28 floats = 112 bytes
	
	# --- USE THE ORIGINAL, STANDARD, COLUMN-MAJOR PACKING ---
	f[ 0] = cam_xform.basis.x.x; f[ 1] = cam_xform.basis.x.y; f[ 2] = cam_xform.basis.x.z; f[ 3] = 0.0
	f[ 4] = cam_xform.basis.y.x; f[ 5] = cam_xform.basis.y.y; f[ 6] = cam_xform.basis.y.z; f[ 7] = 0.0
	f[ 8] = cam_xform.basis.z.x; f[ 9] = cam_xform.basis.z.y; f[10] = cam_xform.basis.z.z; f[11] = 0.0
	f[12] = cam_xform.origin.x;  f[13] = cam_xform.origin.y;  f[14] = cam_xform.origin.z;  f[15] = 1.0
	
	# --- The rest of the push constants ---
	f[16] = sun_dir.x
	f[17] = sun_dir.y
	f[18] = sun_dir.z
	f[19] = Time.get_ticks_msec() / 1000.0
	f[20] = cloud_base
	f[21] = cloud_top
	f[22] = float(screen.x)
	f[23] = float(screen.y)
	f[24] = fov_deg
	f[25] = inv2w
	f[26] = inv3w
	f[27] = 0.0

	return f.to_byte_array()
