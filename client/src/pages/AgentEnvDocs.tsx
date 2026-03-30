import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';

const sections = [
    { id: 'get-env', label: 'Get Env Pack' },
    { id: 'variables', label: 'Variables' },
    { id: 'destination', label: 'Destination Chat' },
    { id: 'examples', label: 'Env Examples' },
];

const dotenvExample = `VIBE_API_BASE_URL=https://api.vibegram.io
VIBE_AGENT_IDENTIFIER=bd35d022-ad48-461a-ac44-f09d165a4232
VIBE_AGENT_SECRET=vas_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
VIBE_DESTINATION_CHAT_ID=73928163c120
VIBE_SOURCE=tradeai
VIBE_TIMEOUT_SECONDS=10`;

const pythonExample = `import os

settings = {
    "api_base_url": os.environ["VIBE_API_BASE_URL"],
    "agent_identifier": os.environ["VIBE_AGENT_IDENTIFIER"],
    "agent_secret": os.environ["VIBE_AGENT_SECRET"],
    "destination_chat_id": os.getenv("VIBE_DESTINATION_CHAT_ID", ""),
    "source": os.getenv("VIBE_SOURCE", "tradeai"),
    "timeout_seconds": int(os.getenv("VIBE_TIMEOUT_SECONDS", "10")),
}`;

const vars = [
    ['VIBE_API_BASE_URL', 'The Vibe API origin. Use the base URL only, not the full `/api/agents/...` endpoint.'],
    ['VIBE_AGENT_IDENTIFIER', 'The agent id or username used in `/api/agents/:identifier/...`.'],
    ['VIBE_AGENT_SECRET', 'The invoke/events secret. Keep it in env only and rotate it from the owner panel when needed.'],
    ['VIBE_DESTINATION_CHAT_ID', 'Optional only when the agent already has a default destination chat. Required for `/events` otherwise.'],
    ['VIBE_SOURCE', 'Short producer label such as `tradeai`, `ops`, or `crm_sync`.'],
    ['VIBE_TIMEOUT_SECONDS', 'Client-side HTTP timeout used by your worker or notifier runtime.'],
];

export default function AgentEnvDocs() {
    return (
        <DocsShell
            eyebrow="ENV_PACK"
            title="Get env and wire your backend"
            intro="Use the owner-facing agent config panel or integration card to copy the env pack, then drop those values into your backend runtime."
            tabs={agentDocsTabs}
            sections={sections}
        >
            <section className="docs-article-section" id="get-env">
                <span className="section-label">GET_ENV_PACK</span>
                <h2 className="docs-article-title">Get the env pack from the owner UI, not from free-form chat text.</h2>
                <p className="docs-article-copy">
                    The clean path is: open the standalone agent config panel, copy the integration pack, then paste the
                    values into your backend `.env` or runtime secret manager. The UI should be treated as the source of
                    truth for the current identifier, current destination chat, and the latest visible secret.
                </p>
                <div className="docs-bullet-card">
                    <div className="docs-mini-row">
                        <strong>Identifier</strong>
                        <span>Copy the published agent id or username from the config panel.</span>
                    </div>
                    <div className="docs-mini-row">
                        <strong>Secret</strong>
                        <span>Copy it immediately after create or rotate, or from the authenticated owner secret endpoint.</span>
                    </div>
                    <div className="docs-mini-row">
                        <strong>Destination chat</strong>
                        <span>Copy the default or attached chat id if your `/events` sender needs explicit delivery routing.</span>
                    </div>
                </div>
            </section>

            <section className="docs-article-section" id="variables">
                <span className="section-label">VARIABLES</span>
                <h2 className="docs-article-title">These are the env variables most backends need.</h2>
                <div className="docs-table-card">
                    {vars.map(([label, description]) => (
                        <div className="docs-table-row docs-table-row-stack" key={label}>
                            <code>{label}</code>
                            <span>{description}</span>
                        </div>
                    ))}
                </div>
            </section>

            <section className="docs-article-section" id="destination">
                <span className="section-label">DESTINATION_CHAT</span>
                <h2 className="docs-article-title">You only need `destinationChatId` for events when the agent has no default destination.</h2>
                <p className="docs-article-copy">
                    `invoke` does not need a Vibe chat destination when your backend wants the reply directly. `events`
                    does need a destination when you want messages posted into Vibe chat, unless the agent already has a
                    valid default destination configured in the owner UI. When in doubt, copy the current destination
                    from the config panel instead of guessing.
                </p>
                <div className="docs-grid-two">
                    <article className="docs-note-card">
                        <h3>Use explicit destination</h3>
                        <p>Set `VIBE_DESTINATION_CHAT_ID` when your sender posts events into a specific DM or team chat.</p>
                    </article>
                    <article className="docs-note-card">
                        <h3>Use default destination</h3>
                        <p>Leave it empty only after the agent already owns a correct default destination chat.</p>
                    </article>
                </div>
            </section>

            <section className="docs-article-section" id="examples">
                <span className="section-label">ENV_EXAMPLES</span>
                <h2 className="docs-article-title">Keep the env block simple and let your code read it directly.</h2>
                <div className="docs-code-grid docs-code-grid-single-mobile">
                    <div className="docs-code-card">
                        <div className="docs-code-label">.env</div>
                        <pre><code>{dotenvExample}</code></pre>
                    </div>
                    <div className="docs-code-card">
                        <div className="docs-code-label">Python settings</div>
                        <pre><code>{pythonExample}</code></pre>
                    </div>
                </div>
            </section>
        </DocsShell>
    );
}
