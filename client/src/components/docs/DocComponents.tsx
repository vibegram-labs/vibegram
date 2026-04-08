import React, { useState } from 'react';
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter';
import { prism } from 'react-syntax-highlighter/dist/esm/styles/prism';

/* ─────────────────────────────────────────────────────────────
   DocSection — wraps each id-anchored section
───────────────────────────────────────────────────────────── */
export function DocSection({
    id,
    children,
}: {
    id: string;
    children: React.ReactNode;
}) {
    return (
        <section className="docs-article-section" id={id}>
            {children}
        </section>
    );
}

/* ─────────────────────────────────────────────────────────────
   Typography helpers
───────────────────────────────────────────────────────────── */
export function DocH2({ children }: { children: React.ReactNode }) {
    return <h2 className="docs-article-h2">{children}</h2>;
}

export function DocH3({ children }: { children: React.ReactNode }) {
    return <h3 className="docs-article-h3">{children}</h3>;
}

export function DocP({ children }: { children: React.ReactNode }) {
    return <p className="docs-article-p">{children}</p>;
}

/* ─────────────────────────────────────────────────────────────
   DocCallout — note / tip / warning / danger
───────────────────────────────────────────────────────────── */
const calloutIcons: Record<string, string> = {
    note: 'ℹ',
    tip: '💡',
    warning: '⚠',
    danger: '🚨',
};

export function DocCallout({
    type = 'note',
    children,
}: {
    type?: 'note' | 'tip' | 'warning' | 'danger';
    children: React.ReactNode;
}) {
    return (
        <div className={`docs-callout docs-callout-${type}`}>
            <span className="docs-callout-icon">{calloutIcons[type]}</span>
            <div className="docs-callout-body"><p>{children}</p></div>
        </div>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocCodeBlock — single code block with copy button
───────────────────────────────────────────────────────────── */
export function DocCodeBlock({ lang, code }: { lang: string; code: string }) {
    const [copied, setCopied] = useState(false);

    const handleCopy = () => {
        navigator.clipboard.writeText(code).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        });
    };

    return (
        <div className="docs-code-block">
            <div className="docs-code-header">
                <span className="docs-code-lang">{lang}</span>
                <button
                    type="button"
                    className={`docs-code-copy ${copied ? 'copied' : ''}`}
                    onClick={handleCopy}
                >
                    {copied ? '✓ Copied' : 'Copy'}
                </button>
            </div>
            <SyntaxHighlighter
                language={lang}
                style={prism}
                customStyle={{
                    margin: 0,
                    padding: '20px',
                    fontSize: '13.5px',
                    lineHeight: '1.65',
                    background: '#ffffff',
                }}
            >
                {code}
            </SyntaxHighlighter>
        </div>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocCodeTabs — tabbed code block with per-tab copy
───────────────────────────────────────────────────────────── */
export interface CodeTab {
    label: string;
    lang: string;
    code: string;
}

export function DocCodeTabs({ tabs }: { tabs: CodeTab[] }) {
    const [active, setActive] = useState(0);
    const [copied, setCopied] = useState(false);

    if (tabs.length === 0) return null;

    const handleCopy = () => {
        navigator.clipboard.writeText(tabs[active].code).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        });
    };

    return (
        <div className="docs-code-tabs">
            <div className="docs-code-tabs-header">
                {tabs.map((tab, i) => (
                    <button
                        key={tab.label}
                        type="button"
                        className={`docs-code-tab-btn ${active === i ? 'active' : ''}`}
                        onClick={() => { setActive(i); setCopied(false); }}
                    >
                        {tab.label}
                    </button>
                ))}
            </div>

            {tabs.map((tab, i) => (
                <div
                    key={tab.label}
                    className={`docs-code-tab-panel ${active === i ? 'active' : ''}`}
                >
                    <button
                        type="button"
                        className={`docs-code-tab-copy ${copied && active === i ? 'copied' : ''}`}
                        onClick={handleCopy}
                    >
                        {copied && active === i ? '✓ Copied' : 'Copy'}
                    </button>
                    <SyntaxHighlighter
                        language={tab.lang}
                        style={prism}
                        customStyle={{
                            margin: 0,
                            padding: '20px',
                            fontSize: '13.5px',
                            lineHeight: '1.65',
                            background: '#ffffff',
                        }}
                    >
                        {tab.code}
                    </SyntaxHighlighter>
                </div>
            ))}
        </div>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocParamTable — field reference table
───────────────────────────────────────────────────────────── */
export interface Param {
    name: string;
    type: string;
    required: boolean;
    desc: string;
}

export function DocParamTable({ params }: { params: Param[] }) {
    return (
        <table className="docs-param-table">
            <thead>
                <tr>
                    <th>Field</th>
                    <th>Type</th>
                    <th>Description</th>
                </tr>
            </thead>
            <tbody>
                {params.map(p => (
                    <tr key={p.name}>
                        <td>
                            <span className="docs-param-name">{p.name}</span>
                            {p.required
                                ? <span className="docs-param-required">required</span>
                                : <span className="docs-param-optional">optional</span>
                            }
                        </td>
                        <td><span className="docs-param-type">{p.type}</span></td>
                        <td><span className="docs-param-desc" dangerouslySetInnerHTML={{ __html: p.desc.replace(/`([^`]+)`/g, '<code>$1</code>') }} /></td>
                    </tr>
                ))}
            </tbody>
        </table>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocSteps — numbered step list
───────────────────────────────────────────────────────────── */
export interface Step {
    title: string;
    body: string;
}

export function DocSteps({ items }: { items: Step[] }) {
    return (
        <ol className="docs-steps">
            {items.map((item, i) => (
                <li key={i} className="docs-step">
                    <span className="docs-step-num">{i + 1}</span>
                    <div className="docs-step-title">{item.title}</div>
                    <div className="docs-step-body"><p>{item.body}</p></div>
                </li>
            ))}
        </ol>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocList — bullet list
───────────────────────────────────────────────────────────── */
export function DocList({ items }: { items: React.ReactNode[] }) {
    return (
        <ul className="docs-list">
            {items.map((item, i) => (
                <li key={i}>{item}</li>
            ))}
        </ul>
    );
}

/* ─────────────────────────────────────────────────────────────
   DocCompareTable — feature comparison grid
───────────────────────────────────────────────────────────── */
export function DocCompareTable({
    columns,
    rows,
}: {
    columns: string[];
    rows: string[][];
}) {
    return (
        <table className="docs-compare-table">
            <thead>
                <tr>
                    {columns.map(col => <th key={col}>{col}</th>)}
                </tr>
            </thead>
            <tbody>
                {rows.map((row, i) => (
                    <tr key={i}>
                        {row.map((cell, j) => (
                            <td key={j}>
                                <span dangerouslySetInnerHTML={{ __html: cell.replace(/`([^`]+)`/g, '<code>$1</code>') }} />
                            </td>
                        ))}
                    </tr>
                ))}
            </tbody>
        </table>
    );
}
