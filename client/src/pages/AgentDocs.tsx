import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';
import {
    DocSection,
    DocH2,
    DocH3,
    DocP,
    DocCallout,
    DocCodeBlock,
    DocCodeTabs,
    DocParamTable,
    DocSteps,
    DocList,
    DocCompareTable,
} from '../components/docs/DocComponents';

const sections = [
    { id: 'overview',   label: 'Overview' },
    { id: 'lifecycle',  label: 'Lifecycle' },
    { id: 'invoke',     label: 'Invoke endpoint' },
    { id: 'events',     label: 'Events endpoint' },
    { id: 'autonomy',   label: 'Autonomy modes' },
    { id: 'response',   label: 'Response modes' },
    { id: 'errors',     label: 'Error reference' },
];

/* ── Code snippets ──────────────────────────────────────────────── */

const invokeCurl = `curl -X POST "https://api.vibegram.io/api/agents/your-agent-id/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxx" \\
  -d '{
    "message": "Summarise today's open alerts",
    "source": "ops_dashboard",
    "responseMode": "reply"
  }'`;

const invokeJs = `const res = await fetch(
  \`\${VIBE_API_BASE_URL}/api/agents/\${VIBE_AGENT_IDENTIFIER}/invoke\`,
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Vibe-Agent-Secret': VIBE_AGENT_SECRET,
    },
    body: JSON.stringify({
      message: 'Summarise today\\'s open alerts',
      source: 'ops_dashboard',
      responseMode: 'reply',   // "reply" | "send"
    }),
  }
);

const data = await res.json();
// { success: true, invocationId: "...", outputs: [...], vibe_deliveries: [...] }`;

const invokePython = `import os, requests

url = f"{os.environ['VIBE_API_BASE_URL']}/api/agents/{os.environ['VIBE_AGENT_IDENTIFIER']}/invoke"

resp = requests.post(
    url,
    json={
        "message": "Summarise today's open alerts",
        "source": "ops_dashboard",
        "responseMode": "reply",
    },
    headers={"X-Vibe-Agent-Secret": os.environ["VIBE_AGENT_SECRET"]},
    timeout=30,
)
resp.raise_for_status()
data = resp.json()  # { "success": True, "invocationId": "...", "outputs": [...] }`;

const eventsCurl = `curl -X POST "https://api.vibegram.io/api/agents/your-agent-id/events" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxx" \\
  -d '{
    "eventId": "trade_10022",
    "eventType": "trade.opened",
    "threadKey": "trade_10022",
    "source": "tradeai",
    "title": "EURUSD buy opened",
    "text": "Buy 0.5 lots EURUSD at 1.0875, SL 1.0840, TP 1.0940",
    "data": { "symbol": "EURUSD", "side": "buy", "entry": 1.0875 },
    "destinationChatId": "73928163c120"
  }'`;

const eventsPython = `import os, requests

url = f"{os.environ['VIBE_API_BASE_URL']}/api/agents/{os.environ['VIBE_AGENT_IDENTIFIER']}/events"

payload = {
    "eventId":    "trade_10022",       # idempotency key – safe to retry
    "eventType":  "trade.opened",
    "threadKey":  "trade_10022",       # groups related events into one thread
    "source":     "tradeai",
    "title":      "EURUSD buy opened",
    "text":       "Buy 0.5 lots EURUSD at 1.0875, SL 1.0840, TP 1.0940",
    "data":       {"symbol": "EURUSD", "side": "buy", "entry": 1.0875},
}

# destinationChatId is optional when the agent already has a default chat
if os.getenv("VIBE_DESTINATION_CHAT_ID"):
    payload["destinationChatId"] = os.environ["VIBE_DESTINATION_CHAT_ID"]

resp = requests.post(
    url,
    json=payload,
    headers={"X-Vibe-Agent-Secret": os.environ["VIBE_AGENT_SECRET"]},
    timeout=10,
)
resp.raise_for_status()`;

const invokeResponse = `{
  "success": true,
  "invocationId": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "outputs": [
    {
      "type": "text",
      "text": "There are 3 open alerts today: ..."
    }
  ],
  "vibe_deliveries": []   // populated when responseMode is "send"
}`;

const eventsResponse = `{
  "ok": true,
  "threadId": "abc123",
  "eventId": "trade_10022",
  "messageId": "msg_xyz",      // set when a Vibe chat bubble was posted
  "decision": "post_thread"   // what the agent decided to do
}`;

export default function AgentDocs() {
    return (
        <DocsShell
            eyebrow="Agents"
            title="Standalone agents"
            intro="Create an agent inside Vibe, publish it, then call it from any backend. The two external entry points are invoke for request-response and events for structured notification streams."
            tabs={agentDocsTabs}
            sections={sections}
        >
            {/* ── Overview ─────────────────────────────────────────── */}
            <DocSection id="overview">
                <DocH2>What is a standalone agent?</DocH2>
                <DocP>
                    A standalone agent is an AI persona you create and configure inside Vibe. It gets its own
                    internal user account (the <em>shadow user</em>), a system prompt, a set of enabled tools,
                    and delivery preferences. Once published, it exposes two HTTP endpoints your backend can call:
                    <code>invoke</code> and <code>events</code>.
                </DocP>
                <DocP>
                    Agents can also participate in Vibe chat threads directly. When a chat member @-mentions an
                    agent, the message is routed to the same runtime as an external invocation — no special
                    integration code needed.
                </DocP>

                <DocCompareTable
                    columns={['Capability', 'Invoke', 'Events']}
                    rows={[
                        ['Direction',         'Request → reply from your backend', 'Push from your backend → Vibe chat'],
                        ['Auth header',       'X-Vibe-Agent-Secret',                'X-Vibe-Agent-Secret or X-Vibe-Integration-Secret'],
                        ['Idempotency key',   'None required',                      'eventId (deduplicated server-side)'],
                        ['Threading',         'None',                               'threadKey groups related events'],
                        ['Chat delivery',     'Optional (responseMode: "send")',    'Automatic when destinationChatId is set'],
                        ['Inbox mode',        'Not applicable',                     'per_event or batched_summary'],
                        ['Approval workflow', 'Not applicable',                     'Yes, driven by autonomy_mode'],
                    ]}
                />
            </DocSection>

            {/* ── Lifecycle ────────────────────────────────────────── */}
            <DocSection id="lifecycle">
                <DocH2>Agent lifecycle</DocH2>
                <DocP>
                    Every agent moves through a defined set of statuses. Only a <code>published</code> agent
                    can accept requests on the invoke and events endpoints — the server returns{' '}
                    <code>403 Agent unavailable</code> for any other status.
                </DocP>

                <DocSteps items={[
                    {
                        title: 'Create (status: draft)',
                        body: 'Create the agent through the Vibe builder chat or the owner API. The secret is generated at creation time — copy it immediately or rotate later from the config panel.',
                    },
                    {
                        title: 'Configure',
                        body: 'Set the system_prompt, enabled_tools, output_modes, autonomy_mode, callback_url, and default_destination_chat_id. A prompt is required before publishing.',
                    },
                    {
                        title: 'Publish (status: published)',
                        body: 'Publishing activates the invoke and events endpoints and locks the username. A published agent can still be updated — changes take effect on the next invocation.',
                    },
                    {
                        title: 'Attach a destination chat (optional)',
                        body: 'If you want event ingestion to automatically post messages into a Vibe chat thread, attach the agent as a participant to that chat and set default_destination_chat_id. Without this, events are stored as thread data only.',
                    },
                    {
                        title: 'Integrate your backend',
                        body: 'Wire up your notifier, trading system, CRM, or any event source to call /invoke or /events using the env pack from the config panel.',
                    },
                    {
                        title: 'Archive (status: archived)',
                        body: 'Archiving removes the agent from participant lists and stops all new invocations. The invocation log is preserved.',
                    },
                ]} />

                <DocCallout type="note">
                    The <code>username</code> field (the public @handle) can only be changed while the agent is in{' '}
                    <code>draft</code> status. After publishing, it is locked and requires a new agent to change.
                </DocCallout>
            </DocSection>

            {/* ── Invoke ───────────────────────────────────────────── */}
            <DocSection id="invoke">
                <DocH2>Invoke endpoint</DocH2>
                <DocP>
                    <code>POST /api/agents/:identifier/invoke</code> submits a message to a published agent and
                    returns the outputs synchronously. The <code>:identifier</code> can be the UUID{' '}
                    <code>agent_id</code> or the <code>@username</code> if one is set.
                </DocP>

                <DocCallout type="note">
                    This endpoint uses the <strong>public agent rate-limit bucket</strong> — it is separate from
                    authenticated user endpoints so your backend traffic does not interfere with user-facing calls.
                </DocCallout>

                <DocH3>Request body</DocH3>
                <DocParamTable params={[
                    { name: 'message',          type: 'string',  required: true,  desc: 'The user message or prompt to send to the agent.' },
                    { name: 'source',           type: 'string',  required: false, desc: 'A short label identifying the caller (e.g. "ops_panel", "tradeai"). Stored in the invocation log.' },
                    { name: 'responseMode',     type: 'string',  required: false, desc: '"reply" (default) — return outputs in the API response. "send" — post outputs to a Vibe chat; requires vibeChatId and the agent to be a participant of that chat.' },
                    { name: 'vibeChatId',       type: 'string',  required: false, desc: 'Required when responseMode is "send". The Vibe chat ID to post the reply into.' },
                    { name: 'outputMode',       type: 'string',  required: false, desc: 'Override the output format for this call: "text" | "voice" | "media". Only works if the mode is in the agent\'s output_modes list.' },
                    { name: 'replyToId',        type: 'string',  required: false, desc: 'Message ID to thread the reply under in Vibe chat.' },
                    { name: 'attachments',      type: 'array',   required: false, desc: 'Array of { type: "image", url: "https://..." } objects passed as vision context to the model.' },
                    { name: 'requesterUserId',  type: 'string',  required: false, desc: 'Optional Vibe user ID of the person requesting output, used for tool context.' },
                    { name: 'eventId',          type: 'string',  required: false, desc: 'Idempotency key stored in the invocation record. Duplicate eventId values for the same agent will not create a second record.' },
                ]} />

                <DocH3>Code examples</DocH3>
                <DocCodeTabs
                    tabs={[
                        { label: 'cURL',       code: invokeCurl,   lang: 'bash'       },
                        { label: 'JavaScript', code: invokeJs,     lang: 'javascript' },
                        { label: 'Python',     code: invokePython, lang: 'python'     },
                    ]}
                />

                <DocH3>Success response</DocH3>
                <DocCodeBlock lang="json" code={invokeResponse} />

                <DocH3>Response fields</DocH3>
                <DocParamTable params={[
                    { name: 'success',        type: 'boolean', required: false, desc: 'Always true on a 200 response.' },
                    { name: 'invocationId',   type: 'string',  required: false, desc: 'UUID of the persisted invocation record. Use this to correlate callback deliveries.' },
                    { name: 'outputs',        type: 'array',   required: false, desc: 'Array of output objects: { type, text, mediaUrl, metadata }. type is "text", "voice", "image", or "file".' },
                    { name: 'vibe_deliveries',type: 'array',   required: false, desc: 'Message IDs of Vibe chat bubbles posted when responseMode is "send".' },
                ]} />
            </DocSection>

            {/* ── Events ───────────────────────────────────────────── */}
            <DocSection id="events">
                <DocH2>Events endpoint</DocH2>
                <DocP>
                    <code>POST /api/agents/:identifier/events</code> ingests a structured event into the
                    agent's event store. The agent decides what to do based on its <code>autonomy_mode</code> and
                    runbook configuration — it may post to Vibe chat, create an approval task, draft a message,
                    or silently log the event.
                </DocP>

                <DocCallout type="tip">
                    Use <code>threadKey</code> to group related events — for example, all events for the same
                    trade ticket share the same threadKey. The agent sees the full thread history when deciding
                    how to handle each new event.
                </DocCallout>

                <DocH3>Request body</DocH3>
                <DocParamTable params={[
                    { name: 'eventType',          type: 'string', required: true,  desc: 'Dot-separated event type, e.g. "trade.opened", "alert.critical", "ticket.updated". Used to match runbook event_types_enabled filters.' },
                    { name: 'eventId',            type: 'string', required: false, desc: 'Idempotency key. If the same eventId is ingested twice, the second call returns the existing result without re-running the agent.' },
                    { name: 'threadKey',          type: 'string', required: false, desc: 'Logical thread identifier. Events sharing a threadKey are grouped into the same AgentEventThread, giving the agent full conversation history.' },
                    { name: 'source',             type: 'string', required: false, desc: 'Short producer label, e.g. "tradeai", "crm_sync". Stored on the event record and visible in the owner thread list.' },
                    { name: 'title',              type: 'string', required: false, desc: 'Short event title shown in the Vibe inbox bubble header.' },
                    { name: 'text',               type: 'string', required: false, desc: 'Human-readable event body. The agent uses this, along with data, to understand the event.' },
                    { name: 'data',               type: 'object', required: false, desc: 'Arbitrary structured payload. Passed as context to the agent runtime alongside the text.' },
                    { name: 'destinationChatId',  type: 'string', required: false, desc: 'Override the agent\'s default_destination_chat_id for this specific event. Required when no default is configured.' },
                    { name: 'occurredAt',         type: 'string', required: false, desc: 'ISO 8601 timestamp of when the event actually occurred. Defaults to server ingestion time if omitted.' },
                    { name: 'attachments',        type: 'array',  required: false, desc: 'Array of { type, url } objects — images or files passed as context to the agent model.' },
                ]} />

                <DocH3>Code examples</DocH3>
                <DocCodeTabs
                    tabs={[
                        { label: 'cURL',   code: eventsCurl,   lang: 'bash'   },
                        { label: 'Python', code: eventsPython, lang: 'python' },
                    ]}
                />

                <DocH3>Success response</DocH3>
                <DocCodeBlock lang="json" code={eventsResponse} />

                <DocCallout type="warning">
                    <strong>Missing destination chat</strong> — if no <code>destinationChatId</code> is in the
                    request and the agent has no <code>default_destination_chat_id</code> configured, the server
                    returns <code>422 Missing destination chat</code>. Always set a default in the config panel or
                    pass the ID per-request.
                </DocCallout>
            </DocSection>

            {/* ── Autonomy Modes ───────────────────────────────────── */}
            <DocSection id="autonomy">
                <DocH2>Autonomy modes</DocH2>
                <DocP>
                    <code>autonomy_mode</code> controls how the agent runtime handles incoming events. It is set
                    at the agent level and can be overridden per-integration. The schema validates the following
                    five values.
                </DocP>

                <DocParamTable params={[
                    { name: 'safe_auto',          type: '(default)', required: false, desc: 'Agent runs automatically for low-risk events. High-risk events (based on runbook risk_level) require owner approval before posting.' },
                    { name: 'full_auto',          type: '',          required: false, desc: 'Agent posts to chat for all events without any approval gate. Use only for fully trusted event sources.' },
                    { name: 'approval_required',  type: '',          required: false, desc: 'Every event triggers an ApprovalTask. The agent drafts the message but waits for the owner to approve or reject from the native config panel.' },
                    { name: 'draft_first',        type: '',          required: false, desc: 'Agent creates a draft message visible only to the owner. Owner promotes it to a real chat message when ready.' },
                    { name: 'manual',             type: '',          required: false, desc: 'Agent only logs the event. No messages are posted and no approval tasks are created. Use for auditing pipelines.' },
                ]} />

                <DocCallout type="note">
                    Runbooks can narrow autonomy further. A runbook with <code>risk_level: "high"</code> will
                    create an approval task even when <code>autonomy_mode</code> is <code>safe_auto</code>.
                </DocCallout>
            </DocSection>

            {/* ── Response Modes ───────────────────────────────────── */}
            <DocSection id="response">
                <DocH2>Response modes (invoke only)</DocH2>
                <DocP>
                    The <code>responseMode</code> field on invoke controls what the server does with generated
                    outputs. There are two options.
                </DocP>

                <DocList items={[
                    <><strong>reply</strong> (default) — Outputs are returned in the HTTP response body. The agent generates text, tool results, or voice audio and sends it back to your caller. No Vibe chat bubble is created.</>,
                    <><strong>send</strong> — Outputs are posted as real messages into the Vibe chat specified by <code>vibeChatId</code>. The agent must already be a participant of that chat (either via a DM or by being added to a group). The response body contains <code>vibe_deliveries</code> with the created message IDs.</>,
                ]} />

                <DocCallout type="tip">
                    Use <code>reply</code> when your backend wants the agent output for its own processing
                    (summaries, classifications, enrichments). Use <code>send</code> when you want the agent to
                    natively participate in a conversation thread visible to the user.
                </DocCallout>
            </DocSection>

            {/* ── Errors ───────────────────────────────────────────── */}
            <DocSection id="errors">
                <DocH2>Error reference</DocH2>
                <DocP>
                    All errors return a JSON body <code>{"{ error: \"message\" }"}</code>. The HTTP status code
                    indicates the category of failure.
                </DocP>

                <DocCompareTable
                    columns={['Status', 'Error body', 'Cause']}
                    rows={[
                        ['400', 'Missing agent identifier',   'identifier path segment is empty or missing'],
                        ['401', 'Invalid secret',             'X-Vibe-Agent-Secret header is missing, wrong, or does not match the stored hash'],
                        ['403', 'Agent unavailable',          'Agent exists but is not in published status (still draft, disabled, or archived)'],
                        ['403', 'Agent not attached to target chat', 'responseMode is "send" but the agent shadow user is not a participant of vibeChatId'],
                        ['404', 'Agent not found',            'No agent matches the identifier (UUID or @username)'],
                        ['422', 'Missing destination chat',   'Events endpoint: no destinationChatId in the payload and no default_destination_chat_id on the agent'],
                        ['422', 'eventType is required',      'Events endpoint: the eventType field is absent from the payload'],
                        ['422', 'Missing message',            'Invoke endpoint: the message field is absent or blank'],
                        ['422', '(other)',                    'Agent runtime error — check the error string for details'],
                    ]}
                />
            </DocSection>
        </DocsShell>
    );
}
