import React from 'react';
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import Chat from './components/Chat';
import Home from './pages/Home';
import AgentDocs from './pages/AgentDocs';

// App Wrapper to handle PWA vs Landing logic
const App = () => {
  // NUCLEAR CLEANUP: Wipe potentially poisoned storage on load
  React.useEffect(() => {
    const saved = localStorage.getItem('proxy_endpoints');
    if (saved && saved.includes('/localhost')) {
      console.warn('[APP] Detected bad endpoints in storage. clearing.');
      localStorage.removeItem('proxy_endpoints');
      localStorage.removeItem('custom_server_url');
      window.location.reload();
    }
    console.log('[APP] Running Build Version: v1.5-FIXED-TOKEN-RACE');
  }, []);

  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/docs/agents" element={<AgentDocs />} />
        <Route path="/app" element={<Chat />} />
        {/* Catch-all redirect to Home or App depending on preference, default to Home for now */}
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
};

export default App;
