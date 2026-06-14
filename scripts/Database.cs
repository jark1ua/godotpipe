using System;
using System.Collections.Generic;
using Godot;
using Microsoft.Data.Sqlite;

// ============================================================================
// Database.cs  (C#)  —  the SQLite persistence layer.
// ----------------------------------------------------------------------------
// Owns one connection to a SQLite file under Godot's writable `user://` area
// (a real OS path obtained via ProjectSettings.GlobalizePath). On first run it
// creates the schema and seeds the item catalog. Three tables:
//
//   items      — content/definitions (seeded once; read-mostly)
//   collected  — persistent record of which items have been picked up
//   save_state — generic key/value store (e.g. last agent position)
//
// This is a plain C# class, not a Godot node: GameManager (an autoload node)
// owns an instance of it. Keeping the engine out of here makes the data layer
// easy to reason about and reuse.
// ============================================================================
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _conn;

    public string Path { get; }

    public Database()
    {
        Path = ProjectSettings.GlobalizePath("user://game.db");
        _conn = new SqliteConnection($"Data Source={Path}");
        _conn.Open();
        EnsureSchema();
        SeedItems();
    }

    private void Exec(string sql, params (string, object)[] args)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (k, v) in args)
            cmd.Parameters.AddWithValue(k, v ?? DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    private void EnsureSchema()
    {
        Exec(@"CREATE TABLE IF NOT EXISTS items (
                   id TEXT PRIMARY KEY,
                   name TEXT NOT NULL,
                   description TEXT NOT NULL,
                   move_speed_bonus REAL NOT NULL DEFAULT 0
               );");
        Exec(@"CREATE TABLE IF NOT EXISTS collected (
                   item_id TEXT PRIMARY KEY,
                   collected_at TEXT NOT NULL
               );");
        Exec(@"CREATE TABLE IF NOT EXISTS save_state (
                   key TEXT PRIMARY KEY,
                   value TEXT NOT NULL
               );");
    }

    // Populate the item catalog only if it's empty, so we don't clobber edits.
    private void SeedItems()
    {
        using (var count = _conn.CreateCommand())
        {
            count.CommandText = "SELECT COUNT(*) FROM items;";
            if (Convert.ToInt64(count.ExecuteScalar()) > 0)
                return;
        }

        AddItem("boots", "Worn Boots", "Light footwear. A small, steady speed boost.", 1.0f);
        AddItem("coil", "Kinetic Coil", "A humming coil that quickens whoever carries it.", 2.0f);
        AddItem("core", "Overclock Core", "Unstable core. A large burst of speed.", 3.5f);
        GD.Print("[C#] Database seeded with item catalog.");
    }

    private void AddItem(string id, string name, string desc, float bonus) =>
        Exec("INSERT INTO items (id, name, description, move_speed_bonus) VALUES ($id, $n, $d, $b);",
            ("$id", id), ("$n", name), ("$d", desc), ("$b", bonus));

    // ---- queries -----------------------------------------------------------

    public Item? GetItem(string id)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT id, name, description, move_speed_bonus FROM items WHERE id = $id;";
        cmd.Parameters.AddWithValue("$id", id);
        using var r = cmd.ExecuteReader();
        if (!r.Read())
            return null;
        return new Item
        {
            Id = r.GetString(0),
            Name = r.GetString(1),
            Description = r.GetString(2),
            MoveSpeedBonus = (float)r.GetDouble(3),
        };
    }

    public List<Item> GetAllItems()
    {
        var list = new List<Item>();
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT id, name, description, move_speed_bonus FROM items ORDER BY move_speed_bonus;";
        using var r = cmd.ExecuteReader();
        while (r.Read())
            list.Add(new Item
            {
                Id = r.GetString(0),
                Name = r.GetString(1),
                Description = r.GetString(2),
                MoveSpeedBonus = (float)r.GetDouble(3),
            });
        return list;
    }

    // ---- persistent records ------------------------------------------------

    public bool IsCollected(string itemId)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT 1 FROM collected WHERE item_id = $id LIMIT 1;";
        cmd.Parameters.AddWithValue("$id", itemId);
        return cmd.ExecuteScalar() != null;
    }

    public void MarkCollected(string itemId) =>
        Exec("INSERT OR REPLACE INTO collected (item_id, collected_at) VALUES ($id, $t);",
            ("$id", itemId), ("$t", DateTime.UtcNow.ToString("o")));

    public int CollectedCount()
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT COUNT(*) FROM collected;";
        return Convert.ToInt32(cmd.ExecuteScalar());
    }

    public void ClearCollected()
    {
        Exec("DELETE FROM collected;");
        Exec("DELETE FROM save_state;");
    }

    // ---- generic key/value save state --------------------------------------

    public void SetState(string key, string value) =>
        Exec("INSERT OR REPLACE INTO save_state (key, value) VALUES ($k, $v);", ("$k", key), ("$v", value));

    public string? GetState(string key)
    {
        using var cmd = _conn.CreateCommand();
        cmd.CommandText = "SELECT value FROM save_state WHERE key = $k;";
        cmd.Parameters.AddWithValue("$k", key);
        return cmd.ExecuteScalar() as string;
    }

    public void Dispose() => _conn.Dispose();
}
