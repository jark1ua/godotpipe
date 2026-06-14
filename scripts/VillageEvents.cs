using System.Threading.Tasks;
using Godot;

// ============================================================================
// VillageEvents.cs  (C#)  —  asynchronous, time-driven world events.
// ----------------------------------------------------------------------------
// Attached to the "Events" node in village.tscn. Demonstrates Godot's C# async
// model: instead of hand-rolling timers in _Process, each event loop is an
// `async Task` that `await`s a SceneTreeTimer signal, runs its effect, and loops.
// Two independent loops run concurrently:
//
//   * Day/night — every few seconds, flip the village between day and night:
//     toggle the lamp lights + lit windows and dim/brighten the sun & ambient.
//   * Crate drops — every few seconds, instance crate.tscn above the square so
//     it falls under gravity onto the ground collider.
//
// The loops self-terminate when the node leaves the tree (scene change), so we
// don't touch freed objects.
// ============================================================================
public partial class VillageEvents : Node
{
    [Export] public float DayNightSeconds = 10.0f;
    [Export] public float CrateEverySeconds = 4.0f;
    [Export] public Vector3 CrateSpawn = new Vector3(0, 8, 0);

    private PackedScene _crateScene = null!;
    private Node3D _lamps = null!;
    private DirectionalLight3D _sun = null!;
    private WorldEnvironment _env = null!;
    private bool _night;

    public override void _Ready()
    {
        _crateScene = GD.Load<PackedScene>("res://scenes/crate.tscn");
        _lamps = GetNode<Node3D>("../Lamps");
        _sun = GetNode<DirectionalLight3D>("../Sun");
        _env = GetNode<WorldEnvironment>("../WorldEnvironment");

        SetNight(false);
        _ = RunDayNight();
        _ = RunCrateDrops();
        GD.Print("[C#] VillageEvents started (async day/night + crate drops).");
    }

    private async Task RunDayNight()
    {
        while (IsInsideTree())
        {
            await ToSignal(GetTree().CreateTimer(DayNightSeconds), SceneTreeTimer.SignalName.Timeout);
            if (!IsInsideTree())
                return;
            SetNight(!_night);
        }
    }

    private async Task RunCrateDrops()
    {
        while (IsInsideTree())
        {
            await ToSignal(GetTree().CreateTimer(CrateEverySeconds), SceneTreeTimer.SignalName.Timeout);
            if (!IsInsideTree())
                return;
            DropCrate();
        }
    }

    private void SetNight(bool night)
    {
        _night = night;

        // Lamps / lit windows on at night, off by day.
        foreach (var child in _lamps.GetChildren())
        {
            if (child is Light3D light)
                light.Visible = night;
            else if (child is GeometryInstance3D geo)
                geo.Visible = night; // lit-window meshes parented under Lamps
        }

        // Sun + ambient sink at night.
        _sun.LightEnergy = night ? 0.15f : 1.2f;
        var env = _env.Environment;
        if (env != null)
        {
            env.AmbientLightEnergy = night ? 0.12f : 0.4f;
            env.BackgroundEnergyMultiplier = night ? 0.25f : 1.0f;
        }

        GD.Print($"[C#] Village is now {(night ? "night" : "day")}.");
    }

    private void DropCrate()
    {
        var crate = _crateScene.Instantiate<RigidBody3D>();
        GetParent().AddChild(crate);
        var jitter = new Vector3((float)GD.RandRange(-2.0, 2.0), 0, (float)GD.RandRange(-2.0, 2.0));
        crate.GlobalPosition = CrateSpawn + jitter;
        crate.AngularVelocity = new Vector3((float)GD.RandRange(-1.0, 1.0), 0, (float)GD.RandRange(-1.0, 1.0));
    }
}
