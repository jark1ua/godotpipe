// ============================================================================
// Item.cs  (C#)  —  a plain data object (POCO), not a Godot node.
// ----------------------------------------------------------------------------
// One row of the `items` table, materialized into a C# object. Kept deliberately
// engine-agnostic: it's just data the Database hands back and the AI consumes.
// This is the kind of thing C# is good at and GDScript is awkward at — strongly
// typed records you query and pass around without touching the scene tree.
// ============================================================================
public sealed class Item
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";

    // Gameplay payload for this slice: how much this item speeds up whoever
    // picks it up. Real games would have many such fields (or a JSON blob col).
    public float MoveSpeedBonus { get; init; }
}
