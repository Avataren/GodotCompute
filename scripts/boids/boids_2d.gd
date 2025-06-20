@tool
extends GPUParticles2D

var num_boids := 300
var boid_pos: Array[Vector2] = []
var boid_vel: Array[Vector2] = []

var image_size:= int(ceil(sqrt(num_boids)))
var boid_data: Image;
var boid_data_texture: ImageTexture

@export_range(0, 100) var friend_radius := 30.0
@export_range(0, 50) var avoid_radius := 15.0
@export_range(0, 100) var min_vel := 25.0
@export_range(0, 300) var max_vel := 50.0

# --- Steering Factors ---
@export_range(0, 5, 0.01) var turn_speed := 0.5
@export_range(0, 10) var alignment_factor := 1.0
@export_range(0, 10) var cohesion_factor := 1.0
@export_range(0, 10) var separation_factor := 2.0
@export_range(0, 100) var edge_margin := 50.0
@export_range(0, 10) var edge_avoid_factor := 3.0


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	_generate_boids()
	boid_data = Image.create(image_size, image_size, false, Image.FORMAT_RGBAF)
	boid_data_texture = ImageTexture.create_from_image(boid_data)
	
	amount = num_boids
	process_material.set_shader_parameter("boid_data", boid_data_texture)

func _generate_boids():
	# Start boids in the center to avoid immediate edge avoidance
	var screen_center = get_viewport_rect().size / 2.0
	for i in num_boids:
		boid_pos.append(screen_center + Vector2(randf_range(-512.0,512.0), randf_range(-512.0,512.0)))
		boid_vel.append(Vector2(randf_range(-1.0,1.0), randf_range(-1.0,1.0)).normalized() * randf_range(min_vel, max_vel))

func _update_texture():
	for i in num_boids:
		var pixel_pos = Vector2(int(i/float(image_size)), int(i%image_size))
		boid_data.set_pixel(pixel_pos.x, pixel_pos.y, Color(boid_pos[i].x, boid_pos[i].y, boid_vel[i].angle(), 0))
		
	boid_data_texture.update(boid_data)
	
func _update_boids_cpu(delta):
	var screen_size = get_viewport_rect().size

	for i in num_boids:
		var my_pos := boid_pos[i]	
		var my_vel := boid_vel[i]
		
		var avg_vel := Vector2.ZERO
		var midpoint := Vector2.ZERO
		var separation_vec := Vector2.ZERO
		var num_friends := 0
		
		# --- Find all boids within the friend_radius ---
		for j in num_boids:
			if (i==j):
				continue
			var other_pos = boid_pos[j]
			var dist_sq = my_pos.distance_squared_to(other_pos) # Use squared distance for efficiency
			
			if (dist_sq < friend_radius * friend_radius):
				num_friends += 1
				avg_vel += boid_vel[j]
				midpoint += other_pos
				if (dist_sq < avoid_radius * avoid_radius):
					separation_vec += my_pos - other_pos
		
		var desired_vel = my_vel
		
		if (num_friends > 0):
			# --- Calculate the 3 steering forces ---
			var alignment_force = (avg_vel / num_friends).normalized() * max_vel
			var cohesion_force = ((midpoint / num_friends) - my_pos).normalized() * max_vel
			var separation_force = separation_vec.normalized() * max_vel
			
			# --- Combine forces to get desired velocity ---
			desired_vel += alignment_force * alignment_factor
			desired_vel += cohesion_force * cohesion_factor
			desired_vel += separation_force * separation_factor
		
		# --- Edge Avoidance ---
		var edge_avoid_force = Vector2.ZERO
		if my_pos.x < edge_margin:
			edge_avoid_force.x = 1
		elif my_pos.x > screen_size.x - edge_margin:
			edge_avoid_force.x = -1
			
		if my_pos.y < edge_margin:
			edge_avoid_force.y = 1
		elif my_pos.y > screen_size.y - edge_margin:
			edge_avoid_force.y = -1
		
		if edge_avoid_force != Vector2.ZERO:
			desired_vel += edge_avoid_force.normalized() * max_vel * edge_avoid_factor
		
		# --- Smooth the turn using lerp ---
		var final_vel = my_vel.lerp(desired_vel, turn_speed * delta)
		
		# --- Clamp velocity and update ---
		final_vel = final_vel.limit_length(max_vel)
		if final_vel.length() < min_vel:
			final_vel = final_vel.normalized() * min_vel
		
		my_vel = final_vel
		my_pos += my_vel * delta
		
		# my_pos = Vector2(wrapf(my_pos.x, 0, screen_size.x),
		# 				wrapf(my_pos.y, 0, screen_size.y))
						
		boid_pos[i] = my_pos
		boid_vel[i] = my_vel

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_update_boids_cpu(delta)
	_update_texture()
