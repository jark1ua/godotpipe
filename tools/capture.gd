extends Node
# ============================================================================
# capture.gd  —  VERIFICATION HARNESS, NOT PART OF THE GAME.
# ----------------------------------------------------------------------------
# Loads a target scene, lets the renderer draw a few frames, reads the
# framebuffer back, writes it to a PNG, and quits. Target scene + output path
# are passed as user args (after `--`), defaulting to the title screen:
#
#   godot --path . tools/capture.tscn -- res://scenes/world.tscn res://docs/world.png
#
# Kept separate from scenes/ so the game itself stays free of capture logic.
# ============================================================================

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/title_screen.tscn"
	var out_path: String = args[1] if args.size() > 1 else "res://docs/title_screen.png"

	var packed: PackedScene = load(scene_path)
	add_child(packed.instantiate())

	# 3D scenes need a couple of frames for the camera/lighting to settle.
	for _i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err := image.save_png(out_path)

	print("CAPTURE_RESULT err=%d size=%s path=%s"
		% [err, str(image.get_size()), ProjectSettings.globalize_path(out_path)])
	get_tree().quit(0 if err == OK else 1)
