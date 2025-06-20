extends GPUParticles2D

var num_boids := 100
var boid_pos = []
var boid_vel = []

var max_vel := 50.0

var image_size:= int(ceil(sqrt(num_boids)))
var boid_data: Image;
var boid_data_texture: ImageTexture

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_generate_boids()
	boid_data = Image.create(image_size, image_size, false, Image.FORMAT_RGBAF)
	boid_data_texture = ImageTexture.create_from_image(boid_data)
	
	amount = num_boids
	process_material.set_shader_parameter("boid_data", boid_data_texture)

func _generate_boids():
	for i in num_boids:
		boid_pos.append(Vector2(randf()* get_viewport_rect().size.x, randf() * get_viewport_rect().size.y))
		boid_vel.append(Vector2(randf_range(-1.0,1.0) * max_vel, randf_range(-1.0,1.0) * max_vel))

func _update_texture():
	for i in num_boids:
		var pixel_pos = Vector2(int(i/float(image_size)), int(i%image_size))
		boid_data.set_pixel(pixel_pos.x, pixel_pos.y, Color(boid_pos[i].x, boid_pos[i].y, boid_vel[i].angle(), 0))
		
	boid_data_texture.update(boid_data)
	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	_update_texture()
