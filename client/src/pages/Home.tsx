import { motion } from 'framer-motion';
import { Shield, Zap, Lock, Radio } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { Header } from '../components/layout/Header';
import './Home.css';

const FadeIn = ({ children, delay = 0 }: { children: React.ReactNode, delay?: number }) => (
    <motion.div
        initial={{ opacity: 0, y: 10 }}
        whileInView={{ opacity: 1, y: 0 }}
        viewport={{ once: true }}
        transition={{ duration: 0.8, delay, ease: [0.21, 0.45, 0.32, 0.9] }}
    >
        {children}
    </motion.div>
);

const SectionLabel = ({ children }: { children: string }) => (
    <span className="section-label">{children}</span>
);

const Hero = () => {
    const navigate = useNavigate();
    return (
        <section className="hero" id="features">
            <div className="hero-content">
                <FadeIn>
                    <SectionLabel>PROTOCOL_V2.5</SectionLabel>
                    <h1 className="hero-title">Sovereign communications<br />engineered for the edge.</h1>
                    <p className="hero-subtitle">
                        A decentralized architecture designed to bypass censorship and secure data through
                        peer-to-peer entropy. No central authority. No data residue.
                    </p>
                    <div className="hero-cta-group">
                        <button className="luxe-button-primary" onClick={() => navigate('/app')}>
                            Launch Node
                        </button>
                        <button className="luxe-button-secondary" onClick={() => navigate('/docs/agents')}>
                            Agent Docs
                        </button>
                    </div>
                </FadeIn>
            </div>
        </section>
    );
};

const NetworkSection = () => (
    <section className="luxe-section" id="network">
        <div className="section-grid">
            <div className="section-info">
                <FadeIn>
                    <SectionLabel>NETWORK.DSTR</SectionLabel>
                    <h2 className="section-title">Peer-to-Peer Mesh Architecture</h2>
                    <p className="section-desc">
                        Vibe operates on a strictly peer-to-peer basis. Connections are established directly
                        between nodes, eliminating the intermediaries that typically harvest metadata or
                        enforce state censorship.
                    </p>
                    <ul className="luxe-list">
                        <li>Direct WebRTC & PeerJS handshakes</li>
                        <li>Dynamic relay node selection</li>
                        <li>Zero-latency routing optimization</li>
                    </ul>
                </FadeIn>
            </div>
            <div className="section-visual">
                <FadeIn delay={0.2}>
                    <div className="mesh-visual">
                        <div className="node node-1"></div>
                        <div className="node node-2"></div>
                        <div className="node node-3"></div>
                        <div className="node node-4"></div>
                        <svg className="mesh-lines">
                            <line x1="20%" y1="20%" x2="80%" y2="80%" />
                            <line x1="80%" y1="20%" x2="20%" y2="80%" />
                            <line x1="50%" y1="10%" x2="50%" y2="90%" />
                        </svg>
                    </div>
                </FadeIn>
            </div>
        </div>
    </section>
);

const SecuritySection = () => (
    <section className="luxe-section bg-soft" id="security">
        <div className="section-grid reverse">
            <div className="section-info">
                <FadeIn>
                    <SectionLabel>CRYPTO.GCM</SectionLabel>
                    <h2 className="section-title">Cryptographic Integrity</h2>
                    <p className="section-desc">
                        Messages are sealed with AES-256-GCM before they leave your device.
                        Public key infrastructure ensures that only the intended recipient possesses
                        the entropy required for decryption.
                    </p>
                    <div className="feature-small-grid">
                        <div className="f-item">
                            <Lock size={14} />
                            <span>RSA-4096 Identity</span>
                        </div>
                        <div className="f-item">
                            <Shield size={14} />
                            <span>Double Ratchet Sealing</span>
                        </div>
                        <div className="f-item">
                            <Zap size={14} />
                            <span>Forward Secrecy</span>
                        </div>
                    </div>
                </FadeIn>
            </div>
            <div className="section-visual">
                <FadeIn delay={0.2}>
                    <div className="security-card">
                        <div className="code-snippet">
                            {`{
  "alg": "AES-256-GCM",
  "iv": "8kf2...m9q4",
  "tag": "verified",
  "cipher": "********"
}`}
                        </div>
                    </div>
                </FadeIn>
            </div>
        </div>
    </section>
);

const BypassSection = () => (
    <section className="luxe-section" id="resilience">
        <div className="section-grid">
            <div className="section-info">
                <FadeIn>
                    <SectionLabel>BYPASS.SHADOW</SectionLabel>
                    <h2 className="section-title">Resilient Routing</h2>
                    <p className="section-desc">
                        Vibe utilizes advanced censorship-bypass techniques including domain fronting
                        and V2Ray-patterned obfuscation to ensure connectivity in the most
                        restrictive network environments.
                    </p>
                    <div className="tech-tags">
                        <span>V2Ray</span>
                        <span>Shadowsocks</span>
                        <span>Domain Fronting</span>
                    </div>
                </FadeIn>
            </div>
            <div className="section-visual">
                <FadeIn delay={0.2}>
                    <div className="routing-visual">
                        <Radio className="pulse-icon" size={32} />
                    </div>
                </FadeIn>
            </div>
        </div>
    </section>
);

const Home = () => {
    return (
        <div className="landing-page luxury-light">
            <Header />
            <Hero />
            <NetworkSection />
            <SecuritySection />
            <BypassSection />

            <footer className="luxe-footer">
                <div className="footer-inner">
                    <div className="footer-top">
                        <span className="logo-small">vibe</span>
                    <div className="footer-nav">
                        <a href="#network">Network</a>
                        <a href="#security">Security</a>
                        <a href="/docs/agents">Docs</a>
                        <a href="#github">Source</a>
                    </div>
                </div>
                    <div className="footer-bottom">
                        <span>© 2026 Vibe. Built for the sovereign edge.</span>
                        <span>0.1.0-ALPHA</span>
                    </div>
                </div>
            </footer>
        </div>
    );
};

export default Home;
