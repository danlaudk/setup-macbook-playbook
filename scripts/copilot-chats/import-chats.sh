#!/bin/bash
# Import GitHub Copilot chat sessions back into VS Code
#
# Usage: ./import-chats.sh [export_dir]
#   export_dir: directory containing exported chats (default: ./copilot-chats-export)
#
# IMPORTANT: Close VS Code before running this script to avoid data corruption.
#
# This script:
#   1. Reads workspace.meta.json from each exported workspace directory
#   2. Locates the matching VS Code workspace storage by hash
#   3. Copies session JSON files into the chatSessions/ directory
#   4. Updates the chat.ChatSessionStore.index in state.vscdb
#   5. Creates a backup of the state.vscdb before modifying it

set -euo pipefail

CODE_DIR="/Users/dlau/Library/Application Support/Code/User"
WS_DIR="${CODE_DIR}/workspaceStorage"
INPUT_DIR="${1:-./copilot-chats-export}"

if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Export directory not found: $INPUT_DIR"
    exit 1
fi

# Check VS Code is not running
if pgrep -x "Code" > /dev/null 2>&1; then
    echo "WARNING: VS Code appears to be running. Close it before importing to avoid data corruption."
    echo "Press Ctrl+C to abort, or Enter to continue at your own risk."
    read -r
fi

imported_count=0
skipped_count=0

for ws_export_dir in "$INPUT_DIR"/*/; do
    [ -d "$ws_export_dir" ] || continue
    [ -f "$ws_export_dir/workspace.meta.json" ] || continue

    # Read workspace metadata
    ws_hash=$(python3 -c "import json; print(json.load(open('$ws_export_dir/workspace.meta.json'))['workspaceHash'])")
    ws_folder=$(python3 -c "import json; print(json.load(open('$ws_export_dir/workspace.meta.json')).get('workspaceFolder',''))")

    # Find the workspace storage directory
    ws_path="$WS_DIR/$ws_hash"
    if [ ! -d "$ws_path" ]; then
        echo "Skipping $ws_folder - workspace storage not found (hash: $ws_hash)"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    # Create chatSessions directory if it doesn't exist
    chat_dir="$ws_path/chatSessions"
    mkdir -p "$chat_dir"

    # Backup state.vscdb
    db_path="$ws_path/state.vscdb"
    if [ -f "$db_path" ]; then
        cp "$db_path" "$db_path.pre-import-backup"
    fi

    # Copy session JSON files (skip non-session files)
    session_files=0
    for json_file in "$ws_export_dir"/*.json; do
        [ -f "$json_file" ] || continue
        filename=$(basename "$json_file")
        # Skip metadata and index files
        case "$filename" in
            workspace.meta.json|chat.ChatSessionStore.index.json) continue ;;
        esac

        # Check if it's a session file (has a UUID-like name)
        if [[ "$filename" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$ ]]; then
            cp "$json_file" "$chat_dir/"
            session_files=$((session_files + 1))
        fi
    done

    # Merge the session index into state.vscdb
    index_file="$ws_export_dir/chat.ChatSessionStore.index.json"
    if [ -f "$index_file" ] && [ -f "$db_path" ]; then
        # Get existing index from the database
        existing_index=$(sqlite3 "$db_path" \
            "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" 2>/dev/null \
            || echo '{"version":1,"entries":{}}')

        # Merge indices using python3
        python3 << PYEOF
import json, sqlite3

db_path = "$db_path"
index_file = "$index_file"

# Load the exported index
with open(index_file) as f:
    exported = json.load(f)

# Load the existing index
try:
    existing = json.loads('''$existing_index''')
except:
    existing = {"version": 1, "entries": {}}

# Merge: exported entries overwrite existing ones with same ID
merged = existing.copy()
merged_entries = dict(merged.get("entries", {}))
merged_entries.update(exported.get("entries", {}))
merged["entries"] = merged_entries

# Write back to database
conn = sqlite3.connect(db_path)
conn.execute("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
             ("chat.ChatSessionStore.index", json.dumps(merged)))
conn.commit()
conn.close()
print(f"Merged {len(exported.get('entries', {}))} session entries into index")
PYEOF
    fi

    echo "Imported $session_files sessions to: $ws_folder"
    imported_count=$((imported_count + session_files))
done

echo ""
echo "Done. Imported $imported_count chat sessions."
if [ $skipped_count -gt 0 ]; then
    echo "Skipped $skipped_count workspaces (storage directory not found)."
fi
echo ""
echo "Note: Backups of state.vscdb saved as .pre-import-backup files."
