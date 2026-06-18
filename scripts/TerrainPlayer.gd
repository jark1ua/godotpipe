extends CharacterBody3D
## Simple grounded player for testing the streamed terrain.
##
## Controls:
##   WASD / mouse  - move + look (mouse is captured on start)
##   Shift         - sprint
##   Space         - jump (or fly up in fly mode)
##   Q / Space,E   - down / up while flying
##   V             - toggle no-clip fly (handy for crossing the 6 km map)
##   Esc           - release the mouse; press again to return to the main menu
##
## Point the TerrainStreamer's Player Path at this node so streaming follows it.

@export var walk_speed: float = 8.0
@export var sprint_speed: float = 22.0
@export var fly_speed: float = 120.0
@export var jump_velocity: float = 6.0
@export var mouse_sensitivity: float = 0.0025

@onready var _cam: Camera3D = $Camera3D

var _gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
var _yaw: float = 0.0
var _pitch: float = 0.0
var _flying: bool = false

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_yaw = rotation.y

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		rotation.y = _yaw            # yaw the body so movement follows the view
		_cam.rotation.x = _pitch     # pitch only the camera
	elif event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_flying = not _flying
		velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	var ix := _axis(KEY_A, KEY_D)
	var iz := _axis(KEY_W, KEY_S)   # -1 forward, +1 back
	var sprint := Input.is_key_pressed(KEY_SHIFT)

	if _flying:
		var iy := _axis(KEY_Q, KEY_E)
		if Input.is_key_pressed(KEY_SPACE):
			iy = 1.0
		# Fly along the camera's full 3D orientation (pitch included).
		var look := _cam.global_transform.basis
		var dir := look * Vector3(ix, 0.0, iz)
		dir.y += iy
		var spd := fly_speed * (3.0 if sprint else 1.0)
		velocity = dir.normalized() * spd if dir.length() > 0.0 else Vector3.ZERO
		move_and_slide()
		return

	# Grounded movement: horizontal from the body's yaw, plus gravity.
	var wish := (transform.basis * Vector3(ix, 0.0, iz))
	wish.y = 0.0
	wish = wish.normalized() if wish.length() > 0.0 else Vector3.ZERO
	var speed := sprint_speed if sprint else walk_speed
	velocity.x = wish.x * speed
	velocity.z = wish.z * speed
	if is_on_floor():
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity
	else:
		velocity.y -= _gravity * delta
	move_and_slide()

static func _axis(neg: Key, pos: Key) -> float:
	return (1.0 if Input.is_key_pressed(pos) else 0.0) - (1.0 if Input.is_key_pressed(neg) else 0.0)
