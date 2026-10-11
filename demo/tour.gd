extends Node3D
## Demo driver: glides the walker sphere around the grass patch and feeds its world
## position to the plugin's global shader parameter, so the blades bend as it passes
## (the same two lines you would add to your own player script).

@onready var _walker: Node3D = $Walker

var _angle := 0.0


func _process(delta: float) -> void:
	_angle += delta * 0.55
	_walker.position = Vector3(cos(_angle) * 4.5, 0.35, sin(_angle) * 4.5)
	RenderingServer.global_shader_parameter_set("grass_player_pos", _walker.global_position)
