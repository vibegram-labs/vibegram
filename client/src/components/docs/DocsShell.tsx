import React from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Header } from '../layout/Header';
import type { AgentDocsTab } from '../../pages/agentDocsShared';
import '../../pages/AgentDocs.css';
import '../../pages/Home.css';

export interface DocsSectionLink {
    id: string;
    label: string;
}

interface DocsShellProps {
    eyebrow: string;
    title: string;
    intro: string;
    tabs: AgentDocsTab[];
    sections: DocsSectionLink[];
    children: React.ReactNode;
}

export default function DocsShell({
    eyebrow,
    title,
    intro,
    tabs,
    sections,
    children,
}: DocsShellProps) {
    const navigate = useNavigate();
    const location = useLocation();

    React.useEffect(() => {
        const targetId = location.hash.replace(/^#/, '');
        if (!targetId) return;
        const node = document.getElementById(targetId);
        if (!node) return;
        window.requestAnimationFrame(() => {
            node.scrollIntoView({ behavior: 'smooth', block: 'start' });
        });
    }, [location.hash]);

    const handleSectionClick = (id: string) => {
        const node = document.getElementById(id);
        if (!node) return;
        node.scrollIntoView({ behavior: 'smooth', block: 'start' });
        window.history.replaceState(null, '', `${location.pathname}#${id}`);
    };

    return (
        <div className="landing-page luxury-light docs-page docs-page-clean">
            <Header />

            <div className="docs-shell">
                <aside className="docs-sidebar">
                    <div className="docs-sidebar-panel">
                        <span className="section-label">{eyebrow}</span>
                        <h1 className="docs-shell-title">{title}</h1>
                        <p className="docs-shell-intro">{intro}</p>
                    </div>

                    <div className="docs-sidebar-panel">
                        <div className="docs-sidebar-label">Documents</div>
                        <div className="docs-sidebar-nav">
                            {tabs.map((tab) => {
                                const active = location.pathname === tab.path;
                                return (
                                    <button
                                        key={tab.path}
                                        type="button"
                                        className={`docs-sidebar-tab ${active ? 'active' : ''}`}
                                        onClick={() => navigate(tab.path)}
                                    >
                                        <span className="docs-sidebar-tab-title">{tab.label}</span>
                                        <span className="docs-sidebar-tab-desc">{tab.description}</span>
                                    </button>
                                );
                            })}
                        </div>
                    </div>

                    <div className="docs-sidebar-panel">
                        <div className="docs-sidebar-label">On This Page</div>
                        <div className="docs-sidebar-sections">
                            {sections.map((section) => (
                                <button
                                    key={section.id}
                                    type="button"
                                    className="docs-sidebar-section"
                                    onClick={() => handleSectionClick(section.id)}
                                >
                                    {section.label}
                                </button>
                            ))}
                        </div>
                    </div>
                </aside>

                <main className="docs-main">
                    <div className="docs-main-scroll">
                        {children}
                    </div>
                </main>
            </div>
        </div>
    );
}
