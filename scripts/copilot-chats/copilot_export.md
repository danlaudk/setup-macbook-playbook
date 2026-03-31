# GitHub Copilot Chat Export/Import for VS Code

Two scripts to back up and restore all GitHub Copilot chat history from VS Code.

## Usage

### Export

```bash
./export-chats.sh [output_dir]
```

Default output directory is `./copilot-chats-export`.

### Import

```bash
# Close VS Code first
./import-chats.sh [export_dir]
```

Default input directory is `./copilot-chats-export`. The script warns if VS Code is running and creates `.pre-import-backup` copies of `state.vscdb` before modifying anything.

## Requirements

- `sqlite3` (built into macOS)
- `python3`
- VS Code data at `~/Library/Application Support/Code/User/`

## How VS Code stores Copilot chats

VS Code stores chat data per-workspace under:

```
~/Library/Application Support/Code/User/workspaceStorage/<hash>/
  workspace.json              # maps hash to folder path (e.g. file:///Users/you/project)
  chatSessions/
    <session-id>.json         # one file per chat session
  state.vscdb                 # SQLite database containing the session index
```

The key findings:

- **Session files** are individual JSON files named by UUID in the `chatSessions/` subdirectory. Each contains the full conversation: requests, responses, model info, timestamps.
- **Session index** is stored in `state.vscdb` (SQLite) under the key `chat.ChatSessionStore.index`. This is a JSON blob with entry metadata (title, dates, etc.) keyed by session ID.
- There is also a global storage at `globalStorage/state.vscdb`, but in practice it had no sessions (`{"version":1,"entries":{}}`).
- Some older workspaces had an `interactive.sessions` key in `state.vscdb` (the format referenced in the GitHub issue), but all were empty arrays. The current VS Code uses the `chatSessions/` file-based approach instead.
- The index can contain entries for sessions whose files no longer exist on disk (stale/deleted). The export script only copies files that actually exist.
- Chat editing sessions (agent mode file edits) are stored separately in `chatEditingSessions/` and are not included in this export.

## Exported directory structure

```
copilot-chats-export/
  _Users_dlau_cognitiveBiases/
    workspace.meta.json                  # workspace hash, folder path, export date
    chat.ChatSessionStore.index.json     # session index
    6868f68c-....json                    # individual chat sessions
    d5d85c86-....json
    ...
  _Users_dlau_overheid_skills-app/
    workspace.meta.json
    chat.ChatSessionStore.index.json
    ...
```

## SQLite commands for manual inspection

The `state.vscdb` files are plain SQLite databases with a single table called `ItemTable` that has two columns: `key` (text) and `value` (text, usually JSON). VS Code uses this as a general-purpose key-value store for all workspace state. These commands help you explore what's stored and manipulate chat data directly.

### Step 1: Find the right workspace directory

Each VS Code project gets its own storage directory under `workspaceStorage/`, identified by an opaque hash. To map hashes to human-readable folder paths:

```bash
for d in ~/Library/Application\ Support/Code/User/workspaceStorage/*/; do
  cat "$d/workspace.json" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('folder',''))" 2>/dev/null
done
```

Then set the DB path for the workspace you want to inspect:

```bash
DB=~/Library/Application\ Support/Code/User/workspaceStorage/<hash>/state.vscdb
```

### Discover what keys exist

When you're unsure what data a workspace contains, list all chat/session-related keys. This reveals which storage format is in use and whether there are agent sessions, terminal sessions, or other extensions storing data:

```bash
sqlite3 "$DB" "SELECT key FROM ItemTable WHERE key LIKE '%chat%' OR key LIKE '%interactive%' OR key LIKE '%session%';"
```

### Read the full session index

The index is the authoritative list of all chat sessions for a workspace. Each entry has the session ID, title, timestamps, and state. Piping through `python3 -m json.tool` pretty-prints the JSON since `sqlite3` outputs it as a single line:

```bash
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" | python3 -m json.tool
```

### Quick session count

Useful to get a sense of scale before deciding whether to dig deeper. A workspace with 0 sessions can be skipped:

```bash
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['entries']))"
```

### List session titles with IDs

The index stores titles but the actual conversation content is in separate files on disk. This command gives you a quick table of contents so you can find a specific chat by name, then use its ID to locate the corresponding file in `chatSessions/<id>.json`:

```bash
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" | python3 -c "
import json,sys
for sid,e in json.load(sys.stdin)['entries'].items():
    print(f'{sid}: {e.get(\"title\",\"(untitled)\")}')
"
```

### Preview a large value safely

Some values in `state.vscdb` can be very large. Using `substr()` limits output to avoid flooding your terminal. This is a good first step before running a full `SELECT value` on an unknown key:

```bash
sqlite3 "$DB" "SELECT substr(value, 1, 500) FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';"
```

### Delete a single session from the index

If you want to remove one chat from VS Code's sidebar without touching others, you need to both delete the file on disk and remove its entry from the index. This command handles the index part. You'd run this together with `rm <hash>/chatSessions/<session-id>.json` to fully remove a session. The import script can later restore it:

```bash
SESSION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" | python3 -c "
import json,sys,sqlite3
db='$DB'; sid='$SESSION_ID'
data=json.load(sys.stdin)
if sid in data['entries']: del data['entries'][sid]
conn=sqlite3.connect(db)
conn.execute('INSERT OR REPLACE INTO ItemTable (key,value) VALUES (?,?)',('chat.ChatSessionStore.index',json.dumps(data)))
conn.commit(); conn.close()
print(f'Done. {len(data[\"entries\"])} entries remain')
"
```

### Find stale index entries

Over time, the index can accumulate entries for sessions whose files were deleted (e.g. VS Code cleaned up old sessions). This cross-references the index against the actual files on disk. These stale entries are harmless but can cause the index count to be higher than the actual number of restorable sessions:

```bash
CHAT_DIR=~/Library/Application\ Support/Code/User/workspaceStorage/<hash>/chatSessions
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'chat.ChatSessionStore.index';" | python3 -c "
import json,sys,os
d=json.load(sys.stdin)
chat_dir='$CHAT_DIR'
for sid in d['entries']:
    if not os.path.exists(f'{chat_dir}/{sid}.json'):
        print(f'Missing: {sid} - {d[\"entries\"][sid].get(\"title\",\"?\")}')
"
```

### Check old-format sessions

Before the current file-per-session format, VS Code stored all chats in a single `interactive.sessions` key as a JSON array. This was the format described in the original GitHub issue. If you're on an older VS Code version or upgrading, check this key — it may still have data:

```bash
sqlite3 "$DB" "SELECT value FROM ItemTable WHERE key = 'interactive.sessions';"
```

### Inspect the global storage DB

There is a separate `state.vscdb` in `globalStorage/` (not per-workspace). It holds cross-workspace settings and extension state. It had an empty chat index in practice, but it's worth checking if chats are missing from the workspace-level databases:

```bash
GLOBAL_DB=~/Library/Application\ Support/Code/User/globalStorage/state.vscdb
sqlite3 "$GLOBAL_DB" "SELECT key FROM ItemTable WHERE key LIKE '%chat%';"
```

## Tested

Verified round-trip on session `15686c8a` ("Understanding Relational Algebra and Codd's Database Insights") from the `cognitiveBiases` workspace:

1. Exported all 75 sessions across 15 workspaces
2. Deleted the target session (file + index entry)
3. Ran import - session file and index entry restored
4. Byte-for-byte content match confirmed
