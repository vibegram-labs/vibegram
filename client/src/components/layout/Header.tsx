import React from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Menu, X } from 'lucide-react';

export const Header = () => {
    const navigate = useNavigate();
    const location = useLocation();
    const [mobileMenuOpen, setMobileMenuOpen] = React.useState(false);
    const isDocsPage = location.pathname.startsWith('/docs');
    const navLinks = isDocsPage
        ? []
        : [
            { label: 'Features', href: '#features' },
            { label: 'Network', href: '#network' },
            { label: 'Security', href: '#security' },
            { label: 'Docs', href: '/docs/agents' },
        ];

    const handleLinkClick = (href: string) => {
        setMobileMenuOpen(false);

        if (href.startsWith('/')) {
            navigate(href);
            return;
        }

        const pageRoot = isDocsPage ? location.pathname : '/';

        if (location.pathname !== pageRoot) {
            navigate(`${pageRoot}${href}`);
            return;
        }

        const targetId = href.replace(/^#/, '');
        const node = document.getElementById(targetId);

        if (node) {
            node.scrollIntoView({ behavior: 'smooth', block: 'start' });
            window.history.replaceState(null, '', `${pageRoot}${href}`);
        }
    };

    return (
        <nav className="landing-nav">
            <div className="nav-content">
                <div className="nav-logo" onClick={() => navigate('/')}>
                    <span className="logo-text">vibe</span>
                </div>

                <div className="nav-center">
                    {!isDocsPage && (
                        <div className={`nav-links ${mobileMenuOpen ? 'open' : ''}`}>
                            {navLinks.map((link) => (
                                <button
                                    key={link.label}
                                    type="button"
                                    onClick={() => handleLinkClick(link.href)}
                                >
                                    {link.label}
                                </button>
                            ))}
                        </div>
                    )}
                </div>

                <div className="nav-actions">
                    {isDocsPage ? (
                        <>
                            <button className="btn-text" onClick={() => navigate('/')}>Home</button>
                            <button className="btn-primary" onClick={() => navigate('/app')}>Open Vibe</button>
                        </>
                    ) : (
                        <>
                            <button className="btn-text" onClick={() => navigate('/docs/agents')}>Docs</button>
                            <button className="btn-text" onClick={() => navigate('/app')}>Sign In</button>
                            <button className="btn-primary" onClick={() => navigate('/app')}>Join</button>

                            <div className="mobile-toggle" onClick={() => setMobileMenuOpen(!mobileMenuOpen)}>
                                {mobileMenuOpen ? <X size={20} /> : <Menu size={20} />}
                            </div>
                        </>
                    )}
                </div>
            </div>
        </nav>
    );
};
