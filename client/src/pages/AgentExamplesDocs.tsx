import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';

const sections = [
    { id: 'invoke', label: 'Invoke' },
    { id: 'events', label: 'Events' },
    { id: 'callback', label: 'Callback Verify' },
];

const invokeCurl = `curl -X POST "$VIBE_API_BASE_URL/api/agents/$VIBE_AGENT_IDENTIFIER/invoke" \\
  -H "Content-Type: application/json" \\
  -H "X-Vibe-Agent-Secret: $VIBE_AGENT_SECRET" \\
  -d '{
    "source": "support_panel",
    "message": "Summarize today\\'s shipment exceptions",
    "responseMode": "reply"
  }'`;

const invokeJs = `const response = await fetch(
  \`\${API_BASE}/api/agents/\${agentIdentifier}/invoke\`,
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Vibe-Agent-Secret': agentSecret,
    },
    body: JSON.stringify({
      source: 'ops_dashboard',
      message: 'Summarize the last five alerts',
      responseMode: 'reply',
    }),
  },
);

const payload = await response.json();`;

const eventsPython = `import os
import requests

url = f"{os.environ['VIBE_API_BASE_URL']}/api/agents/{os.environ['VIBE_AGENT_IDENTIFIER']}/events"
headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "User-Agent": "Vibegram-TradeNotifier/1.0",
    "X-Vibe-Agent-Secret": os.environ["VIBE_AGENT_SECRET"],
}
payload = {
    "eventId": "trade_10021",
    "eventType": "trade.opened",
    "threadKey": "trade_10021",
    "source": "tradeai",
    "title": "Trade opened",
    "text": "EURUSD buy opened at 1.0850",
    "data": {"symbol": "EURUSD", "side": "buy", "entry": 1.0850},
}

if os.getenv("VIBE_DESTINATION_CHAT_ID"):
    payload["destinationChatId"] = os.environ["VIBE_DESTINATION_CHAT_ID"]

response = requests.post(url, json=payload, headers=headers, timeout=10)
response.raise_for_status()`;

const verifySignature = `import crypto from 'node:crypto';

const timestamp = req.header('x-vibe-agent-signature-timestamp') ?? '';
const signature = req.header('x-vibe-agent-signature') ?? '';
const rawBody = req.rawBody.toString('utf8');

const expected = crypto
  .createHmac('sha256', process.env.VIBE_AGENT_SECRET!)
  .update(\`\${timestamp}.\${rawBody}\`)
  .digest('hex');

const valid = crypto.timingSafeEqual(
  Buffer.from(signature),
  Buffer.from(expected),
);`;

export default function AgentExamplesDocs() {
    return (
        <DocsShell
            eyebrow="EXAMPLES"
            title="Code examples"
            intro="Reference snippets for invoke, structured event ingestion, and signed callback verification."
            tabs={agentDocsTabs}
            sections={sections}
        >
            <section className="docs-article-section" id="invoke">
                <span className="section-label">INVOKE</span>
                <h2 className="docs-article-title">Use invoke when your backend wants the agent output back immediately.</h2>
                <div className="docs-code-grid docs-code-grid-single-mobile">
                    <div className="docs-code-card">
                        <div className="docs-code-label">cURL</div>
                        <pre><code>{invokeCurl}</code></pre>
                    </div>
                    <div className="docs-code-card">
                        <div className="docs-code-label">JavaScript</div>
                        <pre><code>{invokeJs}</code></pre>
                    </div>
                </div>
            </section>

            <section className="docs-article-section" id="events">
                <span className="section-label">EVENTS</span>
                <h2 className="docs-article-title">Use events for external notification streams such as trades, alerts, and tickets.</h2>
                <p className="docs-article-copy">
                    The events endpoint is the right choice when you want thread-aware agent inbox behavior, per-event
                    bubbles, or batched summaries in Vibe chat. `destinationChatId` is only needed when the agent has
                    no default destination chat configured yet.
                </p>
                <div className="docs-code-card">
                    <div className="docs-code-label">Python</div>
                    <pre><code>{eventsPython}</code></pre>
                </div>
            </section>

            <section className="docs-article-section" id="callback">
                <span className="section-label">CALLBACK_VERIFY</span>
                <h2 className="docs-article-title">Verify outbound callbacks with the agent secret.</h2>
                <div className="docs-code-card">
                    <div className="docs-code-label">Node</div>
                    <pre><code>{verifySignature}</code></pre>
                </div>
            </section>
        </DocsShell>
    );
}
