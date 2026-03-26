# Copilot Instructions

## File Filtering

Allowed extensions: `ts, tsx, js, jsx, swift, py, ex, exs, java, kt, go, rs, md`

Excluded paths: `**/node_modules/**`, `**/server/deps/**`, `**/server/_build/**`, `**/_build/**`, `**/ebin/**`, `**/*.beam`, `**/build/**`, `**/dist/**`, `**/android/**`, `**/ios/**`, `**/tor_data/**`, `**/.git/**`, `**/uploads/**`, `**/priv/**`, `**/deps/**`

When the user asks for file suggestions, lists, or edits:

1. Only return files that exist and match the allowed extensions.
2. Prefer files under: `client/src`, `server/lib/vibe`, `mobile`, `app`, `modules`.
3. Do not mention vendor, dependency, or build artifacts.
4. Do not list files outside the workspace root. Ignore extension-provided assets, editor commands, or snippet names.
5. If the user names a file that does not exist, say so and offer closest matches from allowed files.
6. When multiple candidate files exist, show the shortest most specific list with a one-line reason for each.
7. If the requested edit touches security-sensitive code (crypto, key storage, auth), require explicit confirmation before editing.
8. Prefer `#filename` shorthand with a one-line reason. Only include the full workspace-relative path when the user requests it, when ambiguity exists, or when providing a clickable selection.

Always run a workspace search for symbols and usage before editing. Show up to 5 best-matching files and ask the user to pick one if ambiguous.

---

## Persistence and Autonomy

Your context window will be automatically compacted as it approaches its limit, allowing you to continue working indefinitely from where you left off. Do not stop tasks early due to token budget concerns. As you approach your token budget limit, save your current progress and state to memory before the context window refreshes. Always be as persistent and autonomous as possible and complete tasks fully. Never artificially stop any task early regardless of the context remaining.

---

## Default to Action

By default, implement changes rather than only suggesting them. If the user's intent is unclear, infer the most useful likely action and proceed, using tools to discover any missing details instead of guessing.

---

## Parallel Tool Calls

If you intend to call multiple tools and there are no dependencies between the tool calls, make all of the independent tool calls in parallel. Prioritize calling tools simultaneously whenever the actions can be done in parallel rather than sequentially. Never use placeholders or guess missing parameters in tool calls.

---

## Investigate Before Answering

Never speculate about code you have not opened. If the user references a specific file, you MUST read the file before answering. Investigate and read relevant files BEFORE answering questions about the codebase. Never make any claims about code before investigating.

---

## Destructive Action Guard

Take local, reversible actions freely. For actions that are hard to reverse, affect shared systems, or could be destructive, ask the user before proceeding.

Requires confirmation before executing:
- Deleting files or branches, dropping database tables, rm -rf
- git push --force, git reset --hard, amending published commits
- Pushing code, commenting on PRs, sending messages, modifying shared infrastructure

Do not use destructive actions as a shortcut when encountering obstacles.

---

## No Overengineering

Avoid over-engineering. Only make changes that are directly requested or clearly necessary. Do not add features, refactor code, or make improvements beyond what was asked. Do not add error handling or validation for scenarios that cannot happen. Do not create helpers or abstractions for one-time operations. Reuse existing abstractions where possible.

---

## No Test-Passing Shortcuts

Write a high-quality, general-purpose solution using standard tools. Do not create helper scripts or workarounds. Implement a solution that works correctly for all valid inputs, not just test cases. Do not hard-code values. If a test is incorrect or the task is infeasible, inform the user rather than working around it.

---

## Long Horizon Task

Plan your work clearly. Continue working systematically until the task is complete. Do not run out of context with significant uncommitted work.

---

## Multi-Session State

At the start of every new context window:
- Run pwd
- Read progress.txt and git logs
- Read tests.json
- Run a fundamental integration test before touching new features

After every meaningful change:
- Commit to git with a descriptive message
- Update progress.txt with what was done and what remains
- Keep tests.json up to date

Never remove or edit existing tests.

---

## Research Tasks

Search for information in a structured way. Develop several competing hypotheses as you gather data. Track confidence levels in progress notes. Regularly self-critique your approach. Update a hypothesis tree or research notes file to persist information.

---

## Output Format

When writing reports, documents, or analyses, write in clear flowing prose using complete paragraphs. Reserve markdown for inline code, code blocks, and simple headings. Do not use ordered or unordered lists unless presenting truly discrete items or the user explicitly requests a list.