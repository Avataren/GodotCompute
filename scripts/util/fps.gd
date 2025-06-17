extends Control

@onready var label: Label = $Panel/Label

# --- internal helpers ---
var _accum_time := 0.0          # how long we’ve been accumulating
var _accum_frames := 0          # how many frames we’ve seen in that time
const UPDATE_INTERVAL := 0.25   # seconds between UI refreshes (tweak to taste)

func _process(delta: float) -> void:
	_accum_time += delta
	_accum_frames += 1

	if _accum_time >= UPDATE_INTERVAL:
		# Average FPS over the sampling window
		var fps := int(round(_accum_frames / _accum_time))
		label.text = "FPS: %d" % fps        # % formatting is fastest/cleanest
		_accum_time = 0.0
		_accum_frames = 0
