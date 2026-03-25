---
description: "Filter file mentions to only relevant editable code files when user asks to list or edit files. Trigger phrases: edit files, modify file, change code, patch, surgical edit, only mention relevant files."
applyTo:
  - "client/src/**"
  - "server/lib/**"
  - "mobile/**"
  - "app/**"
  - "modules/**"
tools: [read, search, edit]
---

When the user asks for file suggestions, lists, or edits, follow these rules:

- Allowed file extensions: `ts, tsx, js, jsx, swift, py, ex, exs, java, kt, go, rs, md`
 - Exclude these paths entirely: `**/node_modules/**`, `**/server/deps/**`, `**/server/_build/**`, `**/_build/**`, `**/ebin/**`, `**/*.beam`, `**/build/**`, `**/dist/**`, `**/android/**`, `**/ios/**`, `**/tor_data/**`, `**/.git/**`, `**/uploads/**`, `**/priv/**`, `**/deps/**`
- Behavior:
  1. Search the workspace and only return files that both exist and match the allowed extensions.
  2. Prefer files under top-level code folders: `client/src`, `server/lib/vibe`, `mobile`, `app`, `modules`.
  3. Do NOT mention vendor, dependency, or build artifacts even if they match an extension.
  4. Only list files that are inside the workspace root. Do NOT list files outside the workspace (for example: `~/.vscode/extensions/**`, `/usr/**`, or other home/system paths) and do NOT surface extension-provided assets, editor commands, or snippet names. Ignore any matches coming from extensions or external directories.
  5. If the user names a file that doesn't exist, say so and offer closest matches from allowed files.
  6. When multiple candidate files exist, show the shortest, most specific list, with a one-line reason for each.
  7. If the requested edit touches security-sensitive code (crypto, key storage, auth), require an explicit confirmation before editing.
  7. When listing candidate files, prefer a concise '#filename' shorthand (for example: #ConnectionManager.ts) with a one-line reason. Only include the full workspace-relative path link when the user requests it, when ambiguity exists, or when providing a clickable selection.

- Search & Confirmation:
  - Always run a workspace search for symbols/usage before editing.
  - Show up to 5 best-matching files and ask the user to pick one if ambiguous.
  - Present the shortlist using the '#filename' shorthand; include the full workspace-relative path link on request or when needed for clarity.

- Examples:
  - User: "Remove console.log from project" → Assistant: list only `client/src/**/*.ts*`, `mobile/**/*.tsx`, `server/lib/**/*.ex` files that contain `console.log` and ask which to modify.
  - User: "Fix reconnect in ConnectionManager.ts" → Assistant: confirm `client/src/ConnectionManager.ts` exists, show its path, then read the file before proposing changes.

This instruction prioritizes accuracy and reduces noisy, irrelevant file mentions. It does not prevent the assistant from searching the web or git history when necessary; it only constrains which workspace files are suggested for edits.
