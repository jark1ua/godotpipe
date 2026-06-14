using Godot;

// ============================================================================
// AgentBrain.cs  (C#)  —  a small real-time AI that ties the slice together.
// ----------------------------------------------------------------------------
// Attached to a Node3D "Agent" in world.tscn. Each frame it runs a tiny
// two-state behaviour:
//
//   SEEK   — if any uncollected pickup remains, steer toward the nearest one;
//            on contact, "use" the item (apply its DB-defined speed bonus),
//            record the pickup in SQLite, and remove it from the world.
//   WANDER — once everything is collected, drift around the plane.
//
// This is the kind of work C# suits: per-frame decision logic with typed data
// pulled from the Database. It reaches the DB through the GameManager autoload
// (GameManager.Instance.Db). Persistence is proven by _Ready: pickups already
// recorded as collected in a previous run are removed immediately, so they
// never reappear.
//
// Pickups are any nodes in the "pickup" group carrying an `item_id` metadata
// string that matches a row in the items table.
// ============================================================================
public partial class AgentBrain : Node3D
{
    [Export] public float BaseSpeed = 1.5f;
    [Export] public float ReachDistance = 0.7f;

    private float _bonus;          // accumulated MoveSpeedBonus from used items
    private float _wanderAngle;

    public override void _Ready()
    {
        // Honor persisted progress: drop any pickup already collected last run.
        foreach (var node in GetTree().GetNodesInGroup("pickup"))
        {
            if (node is Node3D p && GameManager.Instance.IsCollected(ItemIdOf(p)))
                p.QueueFree();
        }
        GD.Print($"[C#] AgentBrain online. {GameManager.Instance.CollectedCount()} item(s) already collected.");
    }

    public override void _Process(double delta)
    {
        Node3D? target = FindNearestPickup();

        if (target != null)
        {
            Vector3 to = target.GlobalPosition - GlobalPosition;
            to.Y = 0.0f;
            if (to.Length() <= ReachDistance)
                Collect(target);
            else
                Step(to.Normalized(), delta);
        }
        else
        {
            // Nothing left to seek: lazy wander so the agent stays alive.
            _wanderAngle += (float)delta * 0.6f;
            Step(new Vector3(Mathf.Cos(_wanderAngle), 0.0f, Mathf.Sin(_wanderAngle)), delta);
        }
    }

    private void Step(Vector3 dir, double delta)
    {
        GlobalPosition += dir * (BaseSpeed + _bonus) * (float)delta;
        // Persist the agent's position as generic save state each step.
        GameManager.Instance.Db.SetState("agent_pos", GlobalPosition.ToString());
    }

    private void Collect(Node3D pickup)
    {
        string id = ItemIdOf(pickup);
        Item? item = GameManager.Instance.Db.GetItem(id);
        if (item != null)
        {
            _bonus += item.MoveSpeedBonus;
            GameManager.Instance.Db.MarkCollected(id);
            GD.Print($"[C#] Agent used '{item.Name}' (+{item.MoveSpeedBonus} speed). Total bonus: {_bonus}.");
        }
        pickup.QueueFree();
    }

    private Node3D? FindNearestPickup()
    {
        Node3D? best = null;
        float bestDist = float.MaxValue;
        foreach (var node in GetTree().GetNodesInGroup("pickup"))
        {
            if (node is not Node3D p || !p.IsInsideTree())
                continue;
            float d = GlobalPosition.DistanceSquaredTo(p.GlobalPosition);
            if (d < bestDist)
            {
                bestDist = d;
                best = p;
            }
        }
        return best;
    }

    private static string ItemIdOf(Node node) =>
        node.HasMeta("item_id") ? node.GetMeta("item_id").AsString() : "";
}
