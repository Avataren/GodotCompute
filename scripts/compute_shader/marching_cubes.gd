# marching_cubes.gd
extends Node3D

const GRID_CELLS := Vector3i(32, 32, 32)
const MAX_VERTS := GRID_CELLS.x * GRID_CELLS.y * GRID_CELLS.z * 5 * 3

@export var noise_texture: NoiseTexture3D
@export var iso_threshold := 0.5
@export var cell_size := Vector3.ONE

var rd: RenderingDevice


# Called when the node enters the scene tree for the first time.
func _ready():
	rd = RenderingServer.create_local_rendering_device()
	generate_mesh()

# Main function to set up and run the compute shader.
func generate_mesh() -> void:
	if not noise_texture:
		printerr("NoiseTexture3D resource has not been assigned in the Inspector.")
		return

	# Load & Compile Compute Shader
	var shader_file : RDShaderFile = load("res://shaders/compute/mc_clouds.glsl")
	var spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader = rd.shader_create_from_spirv(spirv)
	var pipeline = rd.compute_pipeline_create(shader)

	# Get the RID from our pre-made texture.
	# Because we waited a frame, the texture is now fully available.
	var noise_texture_rid = noise_texture.get_rid()

	# Create GPU Buffers (SSBOs)
	var tri_buf_size = MAX_VERTS * 2 * 16
	var tri_buf = rd.storage_buffer_create(tri_buf_size)
	var ctr_buf_size = 4
	var ctr_buf = rd.storage_buffer_create(ctr_buf_size)

	# Set up Uniforms / Bindings
	var sampler_state = RDSamplerState.new()
	var sampler = rd.sampler_create(sampler_state)

	var u_noise = RDUniform.new()
	u_noise.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_noise.binding = 0
	u_noise.add_id(sampler)
	u_noise.add_id(noise_texture_rid)

	var u_tri = RDUniform.new()
	u_tri.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_tri.binding = 1
	u_tri.add_id(tri_buf)

	var u_ctr = RDUniform.new()
	u_ctr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_ctr.binding = 2
	u_ctr.add_id(ctr_buf)

	# This call should now succeed without error.
	var uset = rd.uniform_set_create([u_noise, u_tri, u_ctr], shader, 0)
	if not uset.is_valid():
		printerr("Failed to create Uniform Set even after waiting a frame. This could indicate a deeper issue.")
		return

	# Set up Push Constant Data
	var push_constant = PackedByteArray()
	push_constant.resize(64)
	push_constant.encode_float(0, iso_threshold)
	push_constant.encode_float(16, global_transform.origin.x)
	push_constant.encode_float(20, global_transform.origin.y)
	push_constant.encode_float(24, global_transform.origin.z)
	push_constant.encode_float(32, cell_size.x)
	push_constant.encode_float(36, cell_size.y)
	push_constant.encode_float(40, cell_size.z)
	push_constant.encode_s32(48, GRID_CELLS.x)
	push_constant.encode_s32(52, GRID_CELLS.y)
	push_constant.encode_s32(56, GRID_CELLS.z)

	# Record GPU Commands
	rd.buffer_clear(ctr_buf, 0, ctr_buf_size)
	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_set_push_constant(cl, push_constant, push_constant.size())
	rd.compute_list_dispatch(cl, (GRID_CELLS.x + 7) / 8, (GRID_CELLS.y + 7) / 8, (GRID_CELLS.z + 7) / 8)
	rd.compute_list_end()

	# Submit to GPU and Wait for Completion
	rd.submit()
	rd.sync()

	# Read Back Results
	var ctr_bytes = rd.buffer_get_data(ctr_buf)
	if ctr_bytes.is_empty():
		printerr("Failed to read back counter data.")
		return
		
	var vert_count = ctr_bytes.decode_u32(0)

	if vert_count == 0:
		print("No vertices generated.")
		var old_inst = get_node_or_null("MarchingCubesInstance") as MeshInstance3D
		if is_instance_valid(old_inst):
			old_inst.mesh = null
		rd.free_rid(pipeline); rd.free_rid(shader); rd.free_rid(uset); rd.free_rid(sampler); rd.free_rid(tri_buf); rd.free_rid(ctr_buf)
		return

	vert_count = min(vert_count, MAX_VERTS)
	print("Generated %d vertices." % vert_count)

	var all_bytes = rd.buffer_get_data(tri_buf)
	var used_bytes_size = vert_count * 2 * 16
	var used_bytes = all_bytes.slice(0, used_bytes_size)

	_build_array_mesh(used_bytes, vert_count)
	
	# Clean Up
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free_rid(uset)
	rd.free_rid(sampler)
	rd.free_rid(tri_buf)
	rd.free_rid(ctr_buf)


# Helper function to convert raw byte data from the GPU into a renderable ArrayMesh.
func _build_array_mesh(data_bytes: PackedByteArray, vert_count: int) -> void:
	if vert_count == 0: return

	var floats = data_bytes.to_float32_array()
	var positions = PackedVector3Array()
	var normals   = PackedVector3Array()
	positions.resize(vert_count)
	normals.resize(vert_count)

	for i in range(vert_count):
		var base = i * 8
		positions[i] = Vector3(floats[base+0], floats[base+1], floats[base+2])
		normals[i]   = Vector3(floats[base+4], floats[base+5], floats[base+6])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var inst = get_node_or_null("MarchingCubesInstance") as MeshInstance3D
	if not is_instance_valid(inst):
		inst = MeshInstance3D.new()
		inst.name = "MarchingCubesInstance"
		add_child(inst)
	
	inst.mesh = mesh
