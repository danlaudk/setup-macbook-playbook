#!/bin/bash
# Export all GitHub Copilot chat sessions from VS Code
#
# Usage: ./export-chats.sh [output_dir]
#   output_dir: directory to export chats to (default: ./copilot-chats-export)
#
# Chat data is stored per-workspace in:
#   ~/Library/Application Support/Code/User/workspaceStorage/<hash>/
#     - chatSessions/<session-id>.json  (individual chat session files)
#     - state.vscdb                     (SQLite DB with chat.ChatSessionStore.index)

set -euo pipefail

CODE_DIR="/Users/dlau/Library/Application Support/Code/User"
WS_DIR="${CODE_DIR}/workspaceStorage"
OUTPUT_DIR="${1:-./copilot-chats-export}"

mkdir -p "$OUTPUT_DIR"

exported_count=0
skipped_count=0

for ws_path in "$WS_DIR"/*/; do
    ws_hash=$(basename "$ws_path")

    # Read workspace folder path
    ws_folder=""
    if [ -f "$ws_path/workspace.json" ]; then
        ws_folder=$(python3 -c "
import json,sys
d=json.load(open('$ws_path/workspace.json'))
print(d.get('folder','').replace('file://',''))
" 2>/dev/null || echo "")
    fi

    # Check for chatSessions directory
    chat_dir="$ws_path/chatSessions"
    if [ ! -d "$chat_dir" ]; then
        continue
    fi

    # Get session count from index
    session_count=0
    if [ -f "$ws_path/state.vscdb" ]; then
        session_count=$(sqlite3 "$ws_path/state.vscdb" \
            "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" 2>/dev/null \
            | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d.get('entries',{})))
except: print(0)
" 2>/dev/null || echo "0")
    fi

    if [ "$session_count" -eq 0 ]; then
        continue
    fi

    # Create output directory for this workspace
    safe_name=$(echo "$ws_folder" | tr '/' '_' | tr -cd '[:alnum:]_.-')
    if [ -z "$safe_name" ]; then
        safe_name="unknown_${ws_hash}"
    fi
    ws_output="$OUTPUT_DIR/$safe_name"
    mkdir -p "$ws_output"

    # Export the session index
    if [ -f "$ws_path/state.vscdb" ]; then
        sqlite3 "$ws_path/state.vscdb" \
            "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" \
            > "$ws_output/chat.ChatSessionStore.index.json" 2>/dev/null || true
    fi

    # Copy all session JSON files
    session_files=0
    for session_file in "$chat_dir"/*.json; do
        [ -f "$session_file" ] || continue
        cp "$session_file" "$ws_output/"
        session_files=$((session_files + 1))
    done

    # Save workspace metadata
    cat > "$ws_output/workspace.meta.json" << METAEOF
{
  "workspaceHash": "$ws_hash",
  "workspaceFolder": "$ws_folder",
  "sessionCount": $session_count,
  "exportDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
METAEOF

    echo "Exported $session_files sessions from: $ws_folder"
    exported_count=$((exported_count + session_files))
done

# Also check globalStorage for any global chat data
global_db="$CODE_DIR/globalStorage/state.vscdb"
if [ -f "$global_db" ]; then
    global_index=$(sqlite3 "$global_db" \
        "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" 2>/dev/null || echo "")
    if [ -n "$global_index" ] && [ "$global_index" != '{"version":1,"entries":{}}' ]; then
        mkdir -p "$OUTPUT_DIR/_global"
        echo "$global_index" > "$OUTPUT_DIR/_global/chat.ChatSessionStore.index.json"
        echo "Exported global chat index"
    fi
fi

echo ""
echo "Done. Exported $exported_count chat sessions to: $OUTPUT_DIR"
