extends Node3D

const GRID_CELLS := Vector3i(32, 32, 32)
const MAX_VERTS := GRID_CELLS.x * GRID_CELLS.y * GRID_CELLS.z * 5 * 3

func _ready():
	# —–– 1) Create local device & load compute shader
	var rd := RenderingServer.create_local_rendering_device()
	var shader_file := load("res://shaders/compute/mc_clouds.glsl") as RDShaderFile
	var spirv : RDShaderSPIRV = shader_file.get_spirv()            # reuses your working loader
	var shader = rd.shader_create_from_spirv(spirv)
	var pipeline = rd.compute_pipeline_create(shader)

	# —–– 2) Build a 3D NoiseTexture3D backed by FastNoiseLite
	var noise_tex3d = NoiseTexture3D.new()
	noise_tex3d.width  = GRID_CELLS.x + 1
	noise_tex3d.height = GRID_CELLS.y + 1
	noise_tex3d.depth  = GRID_CELLS.z + 1

	var fn = FastNoiseLite.new()
	fn.seed             = randi()
	fn.fractal_octaves  = 4
	fn.frequency        = 1.0 / 32.0
	fn.fractal_gain     = 0.5
	fn.fractal_lacunarity = 2.0

	noise_tex3d.noise = fn
	await noise_tex3d.changed

	# —–– 3) Allocate SSBOs (triangles + counter)
	var tri_buf_size = MAX_VERTS * 2 * 16        # (pos+normal) × 16 bytes
	var empty_tri = PackedByteArray()
	empty_tri.resize(tri_buf_size)
	var tri_buf = rd.storage_buffer_create(tri_buf_size, empty_tri)

	var empty_ctr = PackedByteArray()
	empty_ctr.resize(4)                          # one uint
	var ctr_buf = rd.storage_buffer_create(4, empty_ctr)

	# —–– 4) Setup uniforms
	var u_noise = RDUniform.new()
	u_noise.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	u_noise.binding      = 0
	u_noise.add_texture(noise_tex3d.get_rid())

	var u_tri = RDUniform.new()
	u_tri.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_tri.binding      = 1
	u_tri.add_id(tri_buf)

	var u_ctr = RDUniform.new()
	u_ctr.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_ctr.binding      = 2
	u_ctr.add_id(ctr_buf)

	var uset = rd.uniform_set_create([u_noise, u_tri, u_ctr], shader, 0)

	# —–– 5) Zero the counter
	var zero4 = PackedByteArray()
	zero4.resize(4)
	rd.buffer_update(ctr_buf, 0, zero4.size(), zero4)

	# —–– 6) Dispatch over the grid
	var cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uset, 0)
	rd.compute_list_dispatch(cl,
		GRID_CELLS.x / 8, GRID_CELLS.y / 8, GRID_CELLS.z / 8
	)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

	# —–– 7) Read back & build mesh
	var ctr_bytes = rd.buffer_get_data(ctr_buf)
	var vert_count = ctr_bytes.decode_u32(0)

	var all_bytes  = rd.buffer_get_data(tri_buf)
	var used_bytes = all_bytes.slice(0, vert_count * 2 * 16)

	_build_array_mesh(used_bytes, vert_count)


func _build_array_mesh(data_bytes: PackedByteArray, vert_count: int) -> void:
	var floats = data_bytes.to_float32_array()
	var positions = PackedVector3Array()
	var normals   = PackedVector3Array()

	for i in vert_count:
		var base = i * 8
		positions.append(Vector3(
			floats[base+0], floats[base+1], floats[base+2]
		))
		normals.append(Vector3(
			floats[base+4], floats[base+5], floats[base+6]
		))

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inst = MeshInstance3D.new()
	inst.mesh = mesh
	add_child(inst)
