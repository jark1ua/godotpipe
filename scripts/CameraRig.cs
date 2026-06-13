using Godot;

// ============================================================================
// CameraRig.cs  (C#  —  Godot .NET)
// ----------------------------------------------------------------------------
// A free-fly camera, written in C# to demonstrate that C# scripts sit on nodes
// exactly like GDScript ones. It moves with WASD/QE relative to where it looks,
// rotates while the right mouse button is held, boosts with Shift, and returns
// to the main menu on Escape. A GDScript HUD (world_hud.gd) reads this node's
// position and the [Export] field below — see that file for the interop side.
//
// Notes for a C++ reader:
//   * `partial` is required: a Godot source generator emits the other half that
//     registers this class with the engine's ClassDB (no manual registration).
//   * `[Export]` surfaces a field to the editor Inspector AND to other scripts
//     (GDScript reads it as "MoveSpeed").
//   * Lifecycle methods (_Ready/_Process/_UnhandledInput) are virtual overrides,
//     the C# equivalents of GDScript's _ready/_process/_unhandled_input.
// ============================================================================
public partial class CameraRig : Camera3D
{
    [Export] public float MoveSpeed = 4.0f;
    [Export] public float BoostMultiplier = 3.0f;
    [Export] public float MouseSensitivity = 0.0025f;

    private float _yaw;
    private float _pitch;
    private bool _looking;

    public override void _Ready()
    {
        // Aim at the cube (which sits at the origin, half a unit tall), then seed
        // yaw/pitch from the resulting orientation so mouse-look starts smoothly.
        LookAt(new Vector3(0.0f, 0.5f, 0.0f), Vector3.Up);
        _yaw = Rotation.Y;
        _pitch = Rotation.X;
        GD.Print($"[C#] CameraRig ready; aimed at cube from {GlobalPosition}.");
    }

    public override void _UnhandledInput(InputEvent @event)
    {
        // Hold the right mouse button to look around.
        if (@event is InputEventMouseButton mb && mb.ButtonIndex == MouseButton.Right)
        {
            _looking = mb.Pressed;
            Input.MouseMode = _looking ? Input.MouseModeEnum.Captured : Input.MouseModeEnum.Visible;
        }
        else if (@event is InputEventMouseMotion mm && _looking)
        {
            _yaw -= mm.Relative.X * MouseSensitivity;
            _pitch = Mathf.Clamp(_pitch - mm.Relative.Y * MouseSensitivity, -1.4f, 1.4f);
            Rotation = new Vector3(_pitch, _yaw, 0.0f);
        }

        // Escape frees the mouse and returns to the menu.
        if (@event.IsActionPressed("ui_cancel"))
        {
            Input.MouseMode = Input.MouseModeEnum.Visible;
            GetTree().ChangeSceneToFile("res://scenes/main_menu.tscn");
        }
    }

    public override void _Process(double delta)
    {
        var wish = new Vector3(
            Axis(Key.A, Key.D),   // X: strafe left/right
            Axis(Key.Q, Key.E),   // Y: down/up
            Axis(Key.W, Key.S));  // Z: forward(-Z)/back

        if (wish == Vector3.Zero)
            return;

        float speed = MoveSpeed * (Input.IsKeyPressed(Key.Shift) ? BoostMultiplier : 1.0f);
        // Transform the wish direction by the camera's orientation so movement is
        // relative to where it is looking, then step by speed * frame time.
        Vector3 motion = (Transform.Basis * wish).Normalized() * speed * (float)delta;
        GlobalPosition += motion;
    }

    // Returns +1 if the positive key is down, -1 if the negative key is down, else 0.
    private static float Axis(Key negative, Key positive) =>
        (Input.IsKeyPressed(positive) ? 1.0f : 0.0f) - (Input.IsKeyPressed(negative) ? 1.0f : 0.0f);
}
