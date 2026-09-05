import type { Metadata } from "next";

import "./globals.css";

export const metadata: Metadata = {
  title: "DCS Telemetry // Command",
  description: "DCS mission telemetry command dashboard",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <div className="hud-shell">
          <header className="hud-topbar">
            <div className="hud-brand">
              DCS // Telemetry Command<small>ops display · duel-dynamic</small>
            </div>
            <div className="hud-clock">UNCLASSIFIED // DEMO DISPLAY</div>
          </header>
          {children}
        </div>
      </body>
    </html>
  );
}
