extends Node3D
## Demo driver: glides the walker sphere around the grass patch and feeds its world
## position to the plugin's global shader parameter, so the blades bend as it passes
## (the same two lines you would add to your own player script).

const PARAM := "shader_globals/grass_player_pos"

@onready var _walker: Node3D = $Walker

var _angle := 0.0


func _ready() -> void:
	# The plugin registers grass_player_pos when enabled in the editor. Running the demo
	# without ever opening the editor (godot --path . from a fresh clone) would miss it,
	# so make sure it exists before the first write — same registration the plugin does.
	if not ProjectSettings.has_setting(PARAM):
		ProjectSettings.set_setting(PARAM, {"type": TYPE_VECTOR3, "value": Vector3(0, 0, -9999)})
	RenderingServer.global_shader_parameter_add(
		"grass_player_pos", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(0, 0, -9999))


func _process(delta: float) -> void:
	_angle += delta * 0.55
	_walker.position = Vector3(cos(_angle) * 4.5, 0.35, sin(_angle) * 4.5)
	RenderingServer.global_shader_parameter_set("grass_player_pos", _walker.global_position)
