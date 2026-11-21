# Connect an agent to Finger

On Finger’s Worktable, click a card to select its files, or click a format such as **SVG** to select one file. Choose **Hand to Codex** to open a new desktop draft with the selected paths. Add your instructions and send the draft when you’re ready. If Codex is unavailable, paste the copied selection into your preferred client.

The Finger MCP tools also let a connected agent read the current selection from either the Worktable or the folder browser and return a named collection to the same window. Each collection entry points to its original file.

## Start in this workspace

Each build registers Finger for the checkout it was built from. Open a new Codex chat in this project or start Claude Code from its directory. The project’s `.codex/config.toml` configures Codex, and its `.mcp.json` configures Claude Code. `scripts/build.sh` writes both with this checkout’s path, so they stay correct if you move the folder and rebuild. Both clients show the server as `finger`. For your first interactive Claude session, accept its project trust and Finger MCP prompts as they appear. Use `/mcp` to inspect the active tools. [Codex MCP setup](https://developers.openai.com/codex/mcp/) · [Claude Code MCP setup](https://code.claude.com/docs/en/mcp)

```sh
cd /path/to/finger
codex mcp get finger
claude mcp get finger
```

To remove the two project registrations, run the commands below from this directory. The macOS `sed` command removes the two-line Codex entry installed by Finger.

```sh
sed -i '' '/^\[mcp_servers\.finger\]$/{ N; /\/finger-mcp"$/d; }' .codex/config.toml
claude mcp remove finger --scope project
```

## Use Finger from other projects

For account-wide local access, use the corresponding command, then open a fresh session. Replace `/path/to/Finger.app` with the app’s location, or copy the commands from **Help → Agent Connection**, which fills in the path of the running app. The Codex CLI and desktop app on the same Codex host share MCP configuration. In the desktop app you can also choose **Settings → MCP servers → Add server**, name it `finger`, select **STDIO**, enter the executable path as **Command**, save, and restart the server. [Codex MCP setup](https://developers.openai.com/codex/mcp/)

```sh
codex mcp add finger -- "/path/to/Finger.app/Contents/MacOS/finger-mcp"
claude mcp add --scope user --transport stdio finger -- "/path/to/Finger.app/Contents/MacOS/finger-mcp"
```

To disconnect a user-wide registration, run `codex mcp remove finger` or `claude mcp remove finger --scope user`.

For a single terminal session in another directory, supply only the corresponding launch command.

```sh
codex -c 'mcp_servers.finger.command="/path/to/Finger.app/Contents/MacOS/finger-mcp"'
claude --mcp-config '{"mcpServers":{"finger":{"command":"/path/to/Finger.app/Contents/MacOS/finger-mcp"}}}'
```

## Claude Desktop

In Claude Desktop, open **Settings → Developer → Edit Config**. Add `finger` to the existing `mcpServers` object in `~/Library/Application Support/Claude/claude_desktop_config.json`. A new config can use the complete example below. Quit and reopen Claude Desktop, then look for the two Finger tools. [Claude Desktop local-server setup](https://modelcontextprotocol.io/docs/develop/connect-local-servers)

```json
{
  "mcpServers": {
    "finger": {
      "command": "/path/to/Finger.app/Contents/MacOS/finger-mcp"
    }
  }
}
```

If you relocate Finger.app, update the executable path in each client. Discovery starts the small stdio bridge. A tool call needs an open Finger window in the same macOS login.

## Try the round trip

1. Choose **File → Open Practice Project** and click the **Overlap 01** card to select its PNG and source SVG.
2. Ask the connected agent, “Read my current Finger selection. Show me a Finger collection called Delivery pair containing those two files.”
3. Return to Finger. The collection opens in the browser. Press **⌘1** to return to the Worktable.

`get_selection` returns the current folder or collection title, selected names and paths, stable item IDs, and a `selection_id`. The first page contains up to 60 items by default. Follow `next_offset` with the same `selection_id` to read more. `show_collection` takes a name, the snapshot ID, and optional ordered `item_ids`. Omit the item IDs to include the full selection. Finger keeps up to 16 snapshots for ten minutes, so a selection change while the agent is composing a result preserves the original items.

An item ID stays attached to its selected file through moves and renames performed in Finger, including moves of a parent folder. Read the same snapshot again for its updated paths. For an external change, Finger checks the device, inode and creation timestamp when available. A detectable replacement returns a tool error asking for a fresh selection. A deleted member can appear as a missing row. If a collection arrives during an in-app move, the agent can retry the same snapshot after the move.

The bridge uses stdio and a private, user-owned Unix socket. Collection requests can refer only to items in a captured selection. The tools expose filenames and paths to the client. The agent's own configuration determines how it uses that information.

## Verification

The reproducible live test uses the selected basenames as a guard before it opens a collection. Replace the two example names with the exact files highlighted in the window.

```sh
cd /path/to/finger
python3 bridge/tests/roundtrip.py --codex --expect "Overlap 01.png" "Overlap 01.svg" --name "Delivery pair"
```

The test starts the installed Codex app-server with an ephemeral thread and temporary configuration, discovers both tools, pages through the selection, checks rejection of an out-of-range item ID, and creates the collection. A fresh selection read confirms that the window is browsing the named collection. Omit `--codex` to exercise the packaged stdio protocol directly. The test makes zero model requests.

`python3 -B bridge/tests/wire_check.py` exercises the bridge on 10,000 separate, disposable files using a private test socket. It checks older clients, expired snapshots, unusual filenames, simultaneous connections, a deleted file, and recovery from a malformed message.

Two scripted Codex app-server checks passed against the live GUI. Codex CLI 0.157.1's app-server read `Overlap 01.png` and `Overlap 01.svg`, created **Press proofs**, and independently read the new collection title. A later run with `/opt/homebrew/bin/codex` (CLI 0.171.0) selected two different files both named `Press proof.png`, opened **Ink comparisons**, and verified both original parent folders in the same window.

A separate hosted Codex CLI 0.171.0 turn used `gpt-6.2-sol` with `codex exec --ephemeral`. The model called `get_selection` for the selected demo PNG and SVG, called `show_collection` to open **Print delivery**, then called `get_selection` again and reported the new title. An independent read through the packaged bridge confirmed the same title in the shipping window. The temporary test configuration restricted the model's Finger access to these two demo paths and this collection.

The large-collection test used `/opt/homebrew/bin/codex`, which resolved to `/opt/homebrew/Caskroom/codex/0.171.0/bin/codex`. Its app-server called both tools against an isolated Finger window using the production bridge source compiled with a private test socket. Fresh Finger processes restored all 10,000 and 100,000 paths in their original order. The test made zero model requests. [Measurements and reproduction](PERFORMANCE.md#named-collections)

Claude Code 2.1.329 completed a separate hosted model turn with the two Finger tools. It read both selected files and called `show_collection` to open **Delivery pair**. A fresh read confirmed that title in the live window. Both installed clients also discovered the tools from their project registrations. Claude Desktop setup follows its documented configuration format and remains untested.
