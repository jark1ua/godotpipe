extends Node
# ============================================================================
# capture.gd  —  VERIFICATION HARNESS, NOT PART OF THE GAME.
# ----------------------------------------------------------------------------
# Purpose: prove, headlessly and without a GPU, that the shipped title screen
# actually renders. It instances the exact scene players would see, lets the
# renderer draw a few frames, reads the framebuffer back, and writes a PNG.
#
# Run it with:
#   xvfb-run -a godot --path . --rendering-method gl_compatibility \
#            --rendering-driver opengl3 tools/capture.tscn
#
# This file is intentionally separate from scenes/ so the game stays script-free.
# ============================================================================

func _ready() -> void:
	# Load + instance the real title screen (same path project.godot boots).
	var packed: PackedScene = load("res://scenes/title_screen.tscn")
	add_child(packed.instantiate())

	# Let the renderer produce real frames before we read pixels back.
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image: Image = get_viewport().get_texture().get_image()

	DirAccess.make_dir_recursive_absolute("res://docs")
	var out_path := "res://docs/title_screen.png"
	var err := image.save_png(out_path)

	# A machine-greppable result line so the shell wrapper can assert success.
	print("CAPTURE_RESULT err=%d size=%s path=%s"
		% [err, str(image.get_size()), ProjectSettings.globalize_path(out_path)])

	get_tree().quit(0 if err == OK else 1)
