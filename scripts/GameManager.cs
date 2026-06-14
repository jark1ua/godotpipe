using Godot;

// ============================================================================
// GameManager.cs  (C#)  —  the game's spine, registered as an autoload.
// ----------------------------------------------------------------------------
// Registered in project.godot under [autoload] as "GameManager", so the engine
// instances exactly one of these at "/root/GameManager" before any scene loads,
// and it stays alive across scene changes. That makes it the natural home for
// process-wide systems — here, the SQLite Database.
//
// Access patterns:
//   * From C#:       GameManager.Instance.Db.GetAllItems()
//   * From GDScript: GameManager.is_collected("boots")  (autoload is a global)
//
// The thin wrapper methods below exist so GDScript (which can't see the C#-only
// Database/Item types) still has a clean, Variant-friendly API to call.
// ============================================================================
public partial class GameManager : Node
{
    public static GameManager Instance { get; private set; } = null!;

    public Database Db { get; private set; } = null!;

    public override void _Ready()
    {
        Instance = this;
        Db = new Database();
        GD.Print($"[C#] GameManager ready. DB: {Db.Path} (collected so far: {Db.CollectedCount()})");
    }

    // Close the connection cleanly when the app shuts down.
    public override void _Notification(int what)
    {
        if (what == NotificationPredelete)
            Db?.Dispose();
    }

    // ---- GDScript-facing wrappers (Variant-friendly types only) ------------

    public bool IsCollected(string itemId) => Db.IsCollected(itemId);

    public int CollectedCount() => Db.CollectedCount();

    public void ResetProgress()
    {
        Db.ClearCollected();
        GD.Print("[C#] Progress reset (collected + save_state cleared).");
    }
}
