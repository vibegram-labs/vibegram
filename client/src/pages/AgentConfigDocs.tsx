import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocCodeBlock,
    DocParamTable,
    DocList,
} from '../components/docs/DocComponents';

const sections = [
    { id: 'overview',    label: 'Overview' },
    { id: 'identity',    label: 'Identity fields' },
    { id: 'behavior',    label: 'Behavior & prompt' },
    { id: 'delivery',    label: 'Delivery & inbox' },
    { id: 'security',    label: 'Security & URLs' },
    { id: 'integration', label: 'Integrations' },
    { id: 'runbooks',    label: 'Runbooks' },
    { id: 'payload',     label: 'Full payload example' },
];

const fullPayload = `{
  "id":                     "bd35d022-ad48-461a-ac44-f09d165a4232",
  "userId":                 "shadow-user-uuid",
  "username":               "trade_sentinel",
  "displayName":            "Trade Sentinel",
  "status":                 "published",
  "systemPrompt":           "You are Trade Sentinel...",
  "persona":                "Concise, professional, data-driven.",
  "avatarUrl":              "https://...",
  "welcomeMessage":         "I track your positions. Ask me anything.",
  "enabledTools":           ["query_event_inbox", "configure_inbox_mode"],
  "outputModes":            ["text", "voice"],
  "autonomyMode":           "safe_auto",
  "defaultDestinationChatId": "73928163c120",
  "eventTypesEnabled":      ["trade.opened", "trade.closed", "alert.critical"],
  "costBudgetDaily":        100,
  "costBudgetMonthly":      2000,
  "approvalRules": {
    "event_inbox": {
      "mode":                "per_event",
      "summary_window_hours": 4
    }
  },
  "runbookIds":             ["rb-uuid-1", "rb-uuid-2"],
  "voiceProvider":          "openai",
  "voiceProfile":           "echo",
  "callbackUrl":            "https://yourbackend.com/vibe-callbacks",
  "secretHint":             "xxxxAB",
  "publishedAt":            "2026-03-01T09:00:00Z",
  "lastInvokedAt":          "2026-03-30T08:12:44Z",
  "attachedChats": [
    { "chatId": "73928163c120", "type": "dm", "name": null, "avatarUrl": null }
  ],
  "integrations": [...],
  "quota": { "used": 1, "limit": 5, "remaining": 4 }
}`;

const createPayload = `curl -X POST "https://api.vibegram.io/api/agents" \\
  -H "Authorization: Bearer USER_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{
    "display_name":  "Trade Sentinel",
    "username":      "trade_sentinel",
    "system_prompt": "You are Trade Sentinel, a trading assistant...",
    "output_modes":  ["text"],
    "autonomy_mode": "safe_auto",
    "callback_url":  "https://yourbackend.com/vibe-callbacks",
    "enabled_tools": ["query_event_inbox"]
  }'`;

const updatePayload = `curl -X PUT "https://api.vibegram.io/api/agents/:id" \\
  -H "Authorization: Bearer USER_TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{
    "system_prompt":               "Updated instruction...",
    "autonomy_mode":               "approval_required",
    "default_destination_chat_id": "newchatid123",
    "approval_rules": {
      "event_inbox": { "mode": "batched_summary", "summary_window_hours": 4 }
    }
  }'`;

export default function AgentConfigDocs() {
    return (
        <DocsShell
            eyebrow="Agents"
            title="Config reference"
            intro="Complete field-by-field reference for the agent config model. The same fields appear in the builder, the native owner panel, and the owner REST API."
            tabs={agentDocsTabs}
            sections={sections}
        >
            {/* ── Overview ─────────────────────────────────────── */}
            <DocSection id="overview">
                <DocH2>How the config model is shared</DocH2>
                <DocP>
                    The agent config is a single Ecto schema (<code>Vibe.Agent</code>) stored in the{' '}
                    <code>agents</code> table. Every surface that touches an agent — the builder chat, the
                    native owner config panel, and the REST API — reads and writes the same record. The
                    serialized form returned by the API (<code>agent_payload/2</code>) is the canonical
                    representation.
                </DocP>
                <DocP>
                    Two endpoints modify the config: <code>PUT /api/agents/:id</code> (general update) and
                    <code>POST /api/agents/:id/publish</code> (status transition only). All fields except
                    <code>username</code> can be changed after publishing.
                </DocP>

                <DocCallout type="note">
                    <strong>Owner-only access.</strong> All config endpoints require an authenticated Vibe session
                    token (<code>Authorization: Bearer …</code>) and enforce that{' '}
                    <code>current_user.id == agent.owner_user_id</code>. The external invoke and events endpoints
                    use the agent secret instead and do not require a user session.
                </DocCallout>

                <DocH3>Create an agent</DocH3>
                <DocCodeBlock lang="bash" code={createPayload} />

                <DocH3>Update an agent</DocH3>
                <DocCodeBlock lang="bash" code={updatePayload} />
            </DocSection>

            {/* ── Identity ─────────────────────────────────────── */}
            <DocSection id="identity">
                <DocH2>Identity fields</DocH2>
                <DocP>
                    These fields define how the agent is identified internally, publicly, and in owner UIs.
                </DocP>

                <DocParamTable params={[
                    { name: 'id',           type: 'uuid',   required: false, desc: 'Canonical agent UUID. Always works as an :identifier in invoke and events endpoints. Immutable after creation.' },
                    { name: 'userId',       type: 'uuid',   required: false, desc: 'UUID of the shadow user account created for this agent. This is the from_id on all agent-sent messages.' },
                    { name: 'username',     type: 'string', required: false, desc: 'Public @handle. Alphanumeric + underscore, 3–30 chars. Can only be set during draft status. If set, works as an :identifier in place of the UUID.' },
                    { name: 'displayName',  type: 'string', required: true,  desc: 'Human-readable name shown in chat headers, notifications, and the owner home list. 1–80 characters.' },
                    { name: 'status',       type: 'enum',   required: false, desc: '"draft" | "published" | "disabled" | "archived". Only published agents accept external calls. Transitions: draft → published (via /publish), published → disabled or archived (via PUT).' },
                    { name: 'avatarUrl',    type: 'string', required: false, desc: 'HTTPS URL for the agent\'s avatar image. Shown in chat bubbles and the owner list.' },
                    { name: 'persona',      type: 'string', required: false, desc: 'Short personality descriptor prepended to the system prompt automatically, e.g. "Concise, professional."' },
                    { name: 'welcomeMessage', type: 'string', required: false, desc: 'A line appended to the system prompt: "Welcome message: {value}". Used to seed the agent\'s first-message tone.' },
                    { name: 'publishedAt',  type: 'datetime', required: false, desc: 'UTC timestamp of the most recent publish action. Null for draft agents.' },
                    { name: 'lastInvokedAt', type: 'datetime', required: false, desc: 'UTC timestamp of the last successful invocation. Updated after every invoke and event ingestion.' },
                ]} />
            </DocSection>

            {/* ── Behavior ─────────────────────────────────────── */}
            <DocSection id="behavior">
                <DocH2>Behavior & prompt fields</DocH2>
                <DocP>
                    These fields control what the agent knows, which tools it can call, and what format its
                    outputs take.
                </DocP>

                <DocParamTable params={[
                    { name: 'systemPrompt',   type: 'string',   required: true,  desc: 'The full instruction set for the agent. Required before publishing. Automatically enriched with persona, welcomeMessage, and an internal preamble at runtime.' },
                    { name: 'enabledTools',   type: 'string[]', required: false, desc: 'Registry IDs of tools the agent is allowed to call (e.g. "query_event_inbox", "configure_inbox_mode"). Invalid IDs are silently dropped. Defaults to the ToolRegistry default set.' },
                    { name: 'outputModes',    type: 'string[]', required: false, desc: 'Allowed response types: "text" | "media" | "voice". Defaults to ["text"]. "voice" requires an OpenAI API key in the server environment.' },
                    { name: 'autonomyMode',   type: 'enum',     required: false, desc: '"safe_auto" | "full_auto" | "approval_required" | "draft_first" | "manual". Controls how the agent handles ingested events. Defaults to "safe_auto".' },
                    { name: 'voiceProvider',  type: 'string',   required: false, desc: 'TTS provider to use when outputModes includes "voice". Currently only "openai" is supported.' },
                    { name: 'voiceProfile',   type: 'string',   required: false, desc: 'OpenAI TTS voice preset: "alloy" | "echo" | "fable" | "onyx" | "nova" | "shimmer". Defaults to "alloy".' },
                    { name: 'costBudgetDaily',   type: 'integer', required: false, desc: 'Optional soft cap on daily AI cost in micro-USD (100 = $0.00010). If exceeded, the server logs a warning but does not block the call.' },
                    { name: 'costBudgetMonthly', type: 'integer', required: false, desc: 'Same as costBudgetDaily but monthly.' },
                ]} />

                <DocCallout type="tip">
                    The server assembles the final system prompt at runtime:{' '}
                    <code>"You are {'{'}displayName{'}'}, …" + persona + welcomeMessage + systemPrompt</code>.
                    You do not need to repeat the name in your prompt.
                </DocCallout>
            </DocSection>

            {/* ── Delivery ─────────────────────────────────────── */}
            <DocSection id="delivery">
                <DocH2>Delivery & inbox fields</DocH2>
                <DocP>
                    These fields control where event output is delivered in Vibe and how the inbox thread is
                    shown.
                </DocP>

                <DocParamTable params={[
                    { name: 'defaultDestinationChatId', type: 'string',   required: false, desc: 'Vibe chat ID where event ingestion posts messages when the request does not include destinationChatId. Can be a DM ID or group ID. The agent shadow user must be a participant of this chat.' },
                    { name: 'eventTypesEnabled',        type: 'string[]', required: false, desc: 'Allow-list of eventType values the agent will process. An empty array means all types are accepted. Useful for filtering high-volume sources.' },
                    { name: 'attachedChats',            type: 'array',    required: false, desc: 'Read-only. Chats where both the agent shadow user and the owner are current participants. Populated by the API response.' },
                    { name: 'approvalRules',            type: 'object',   required: false, desc: 'Nested delivery configuration (see below).' },
                    { name: 'approvalRules.event_inbox.mode', type: 'enum', required: false, desc: '"per_event" — one chat bubble per ingested event. "batched_summary" — events are collected and the agent posts a summary on a configurable cadence.' },
                    { name: 'approvalRules.event_inbox.summary_window_hours', type: 'integer', required: false, desc: 'Cadence for batched_summary mode. The owner UI exposes 4 (every 4 hours) and 24 (daily).' },
                    { name: 'runbookIds',               type: 'uuid[]',   required: false, desc: 'Read-only. UUIDs of all AgentRunbook records attached to this agent across all integrations.' },
                ]} />

                <DocList items={[
                    <><strong>per_event</strong> — Each ingested event creates a new chat bubble immediately. Good for real-time alerting where every event needs immediate visibility.</>,
                    <><strong>batched_summary</strong> — Events are queued. The agent posts a consolidated summary message at each cadence boundary. Good for high-volume sources where individual bubbles would be noisy.</>,
                ]} />
            </DocSection>

            {/* ── Security ─────────────────────────────────────── */}
            <DocSection id="security">
                <DocH2>Security & integration URL fields</DocH2>
                <DocP>
                    The agent secret is used for two separate purposes: authenticating external callers on the
                    invoke and events endpoints, and signing outbound callback payloads.
                </DocP>

                <DocParamTable params={[
                    { name: 'secretHint',    type: 'string', required: false, desc: 'Last 6 characters of the current secret. Always safe to read. Use to verify which secret version is active without exposing the full value.' },
                    { name: 'latestSecret',  type: 'string', required: false, desc: 'Full secret — only exposed in the create response, the rotate response, or via GET /api/agents/:id/secret (owner auth required). Store it in your secrets manager immediately.' },
                    { name: 'callbackUrl',   type: 'string', required: false, desc: 'HTTPS URL your backend exposes to receive outbound webhook deliveries (invocation completed, message delivered, message failed). Optional. Leave blank to opt out.' },
                    { name: 'invokeUrl',     type: 'string', required: false, desc: 'Computed read-only URL: {API_BASE}/api/agents/{identifier}/invoke. Copy from the integration pack in the UI.' },
                    { name: 'eventsUrl',     type: 'string', required: false, desc: 'Computed read-only URL: {API_BASE}/api/agents/{identifier}/events. Copy from the integration pack in the UI.' },
                ]} />

                <DocCallout type="warning">
                    Secrets are stored as AES-256-GCM encrypted blobs and SHA-256 hashes — the plaintext is
                    never stored. The API returns the plaintext exactly once (create or rotate). After that,{' '}
                    <code>GET /api/agents/:id/secret</code> re-decrypts and returns it using the server
                    encryption key (<code>VIBE_AGENT_SECRET_ENCRYPTION_KEY</code>).
                </DocCallout>
            </DocSection>

            {/* ── Integrations ─────────────────────────────────── */}
            <DocSection id="integration">
                <DocH2>Integrations</DocH2>
                <DocP>
                    An integration (<code>AgentIntegration</code>) is a named connection point between an agent
                    and an external data source. Each integration has its own secret, autonomy mode override,
                    destination chat, and runbook set. This lets a single agent handle events from multiple
                    sources with different routing rules.
                </DocP>

                <DocParamTable params={[
                    { name: 'id',                      type: 'uuid',     required: false, desc: 'Integration UUID.' },
                    { name: 'name',                    type: 'string',   required: false, desc: 'Human-readable label, e.g. "TradeAI Production" or "PagerDuty".' },
                    { name: 'sourceType',              type: 'string',   required: false, desc: 'Short machine label for the source, e.g. "tradeai", "pager_duty", "custom".' },
                    { name: 'autonomyMode',            type: 'enum',     required: false, desc: 'Overrides the agent-level autonomy_mode for events arriving via this integration.' },
                    { name: 'defaultDestinationChatId', type: 'string',  required: false, desc: 'Overrides the agent-level default_destination_chat_id for this integration.' },
                    { name: 'eventTypesEnabled',       type: 'string[]', required: false, desc: 'Allow-list scoped to this integration. Empty array means all types are accepted.' },
                    { name: 'routingRules',            type: 'object',   required: false, desc: 'Reserved for future routing logic. Currently unused at runtime.' },
                    { name: 'approvalRules',           type: 'object',   required: false, desc: 'Same shape as the agent-level approvalRules. Overrides per-integration.' },
                    { name: 'enabled',                 type: 'boolean',  required: false, desc: 'If false, events arriving via this integration\'s secret are rejected.' },
                    { name: 'secretHint',              type: 'string',   required: false, desc: 'Last 6 chars of the integration secret. A separate secret from the main agent secret.' },
                    { name: 'lastEventAt',             type: 'datetime', required: false, desc: 'UTC timestamp of the last event received via this integration.' },
                    { name: 'runbooks',                type: 'array',    required: false, desc: 'Runbook records scoped to this integration (see Runbooks section).' },
                ]} />

                <DocCallout type="note">
                    When calling the events endpoint, use either the main agent secret or the integration secret.
                    The header is the same (<code>X-Vibe-Agent-Secret</code> or{' '}
                    <code>X-Vibe-Integration-Secret</code>). The server identifies which integration matched and
                    applies its autonomy and routing overrides.
                </DocCallout>
            </DocSection>

            {/* ── Runbooks ─────────────────────────────────────── */}
            <DocSection id="runbooks">
                <DocH2>Runbooks</DocH2>
                <DocP>
                    A runbook (<code>AgentRunbook</code>) defines an automated action the agent should take for
                    matching events. Runbooks are created alongside integrations and evaluated at event ingestion
                    time.
                </DocP>

                <DocParamTable params={[
                    { name: 'name',               type: 'string',   required: false, desc: 'Human-readable name for the runbook.' },
                    { name: 'eventTypesEnabled',  type: 'string[]', required: false, desc: 'Event types this runbook applies to. Empty means all types.' },
                    { name: 'riskLevel',          type: 'enum',     required: false, desc: '"low" | "medium" | "high". High-risk runbooks trigger an approval task even in safe_auto mode.' },
                    { name: 'actionType',         type: 'string',   required: false, desc: '"post_message" (default) or custom action types defined by the runtime.' },
                    { name: 'instructions',       type: 'string',   required: false, desc: 'Instruction text passed to the agent when this runbook is triggered. Used as additional context on top of the system prompt.' },
                    { name: 'conditions',         type: 'object',   required: false, desc: 'Filtering conditions evaluated against the event payload before triggering the runbook.' },
                    { name: 'actionConfig',       type: 'object',   required: false, desc: 'Action-specific config. For "post_message", can include a "message" template string.' },
                    { name: 'enabled',            type: 'boolean',  required: false, desc: 'Whether the runbook is active. Defaults to true.' },
                ]} />
            </DocSection>

            {/* ── Full payload ─────────────────────────────────── */}
            <DocSection id="payload">
                <DocH2>Full payload example</DocH2>
                <DocP>
                    This is the complete JSON shape returned by <code>GET /api/agents/:id</code> and included
                    in create/update responses.
                </DocP>
                <DocCodeBlock lang="json" code={fullPayload} />
            </DocSection>
        </DocsShell>
    );
}
