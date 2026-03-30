import DocsShell from '../components/docs/DocsShell';
import { agentDocsTabs } from './agentDocsShared';

const sections = [
    { id: 'overview', label: 'Overview' },
    { id: 'builder', label: 'Build In Vibe' },
    { id: 'invoke', label: 'Invoke & Events' },
    { id: 'callbacks', label: 'Callbacks' },
];

export default function AgentDocs() {
    return (
        <DocsShell
            eyebrow="AGENTS"
            title="Standalone agents in Vibe"
            intro="Create the agent in Vibe, publish it, then call it from your backend or send structured event streams into chat threads."
            tabs={agentDocsTabs}
            sections={sections}
        >
            <section className="docs-article-section" id="overview">
                <span className="section-label">OVERVIEW</span>
                <h2 className="docs-article-title">The main flow is create, publish, attach, then integrate.</h2>
                <p className="docs-article-copy">
                    Standalone agents live inside Vibe but can also be called from external backends. The clean split is:
                    create and configure the agent in Vibe, publish it, attach it to a Vibe chat when you want in-app
                    delivery, then use the invoke or events endpoint from your own system.
                </p>
                <div className="docs-bullet-card">
                    <div className="docs-mini-row">
                        <strong>Create in Vibe</strong>
                        <span>name, prompt, tools, output modes, voice, callback</span>
                    </div>
                    <div className="docs-mini-row">
                        <strong>Publish</strong>
                        <span>activates invoke and events endpoints</span>
                    </div>
                    <div className="docs-mini-row">
                        <strong>Attach a destination chat</strong>
                        <span>required when you want external events to post inside Vibe chat</span>
                    </div>
                    <div className="docs-mini-row">
                        <strong>Integrate</strong>
                        <span>use invoke for direct replies, events for structured notification threads</span>
                    </div>
                </div>
            </section>

            <section className="docs-article-section" id="builder">
                <span className="section-label">BUILD_IN_VIBE</span>
                <h2 className="docs-article-title">The builder and native config panel cover the owner workflow.</h2>
                <p className="docs-article-copy">
                    Owners can create agents through the builder chat and refine them later in the native config panel.
                    That panel is where rename, prompt viewing, secret rotation, delivery ids, and inbox mode now live.
                </p>
                <div className="docs-grid-two">
                    <article className="docs-note-card">
                        <h3>Builder</h3>
                        <p>Use the builder to create the prompt, enable tools, reserve a username, and publish the agent.</p>
                    </article>
                    <article className="docs-note-card">
                        <h3>Config Panel</h3>
                        <p>Use the config sheet to inspect the integration pack, copy ids, rotate the secret, rename the agent, and switch inbox mode.</p>
                    </article>
                </div>
            </section>

            <section className="docs-article-section" id="invoke">
                <span className="section-label">INVOKE_AND_EVENTS</span>
                <h2 className="docs-article-title">Use invoke for request-response and events for external notification streams.</h2>
                <p className="docs-article-copy">
                    `POST /api/agents/:identifier/invoke` is the direct execution path. `POST /api/agents/:identifier/events`
                    is the structured ingestion path for trades, alerts, tickets, orders, and similar event feeds. If the
                    agent already has a default destination chat, `destinationChatId` is optional for events.
                </p>
                <div className="docs-table-card">
                    <div className="docs-table-row">
                        <strong>Invoke</strong>
                        <span>Call the agent and receive outputs back to your backend.</span>
                    </div>
                    <div className="docs-table-row">
                        <strong>Events</strong>
                        <span>Persist external notifications, thread them by `threadKey`, and optionally post them into Vibe chat.</span>
                    </div>
                    <div className="docs-table-row">
                        <strong>Inbox mode</strong>
                        <span>Choose between per-event bubbles and batched summaries for those ingested events.</span>
                    </div>
                </div>
            </section>

            <section className="docs-article-section" id="callbacks">
                <span className="section-label">CALLBACKS</span>
                <h2 className="docs-article-title">Outbound callbacks use the same agent secret for HMAC verification.</h2>
                <p className="docs-article-copy">
                    When a callback URL is configured, Vibe signs outbound delivery payloads with
                    `hex(hmac_sha256(secret, "{`timestamp`}.{`rawBody`}"))`. Use that to verify invocation and delivery
                    callbacks before processing them in your backend.
                </p>
                <div className="docs-note-card">
                    <h3>Callback events</h3>
                    <p>`agent.invocation.completed`, `agent.message.delivered`, and `agent.message.failed` are the primary outbound events currently documented.</p>
                </div>
            </section>
        </DocsShell>
    );
}
