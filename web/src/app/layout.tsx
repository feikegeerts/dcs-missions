import type { Metadata } from "next";
import Link from "next/link";
import { Barlow_Condensed, Inter } from "next/font/google";

import "./globals.css";

// Next bundles the font files with the app; visitors do not call Google Fonts.
const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
  display: "swap",
});
const barlow = Barlow_Condensed({
  subsets: ["latin"],
  weight: "600",
  variable: "--font-barlow",
  display: "swap",
});

export const metadata: Metadata = {
  title: "DCS Mission Control",
  description: "DCS mission telemetry command dashboard",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${inter.variable} ${barlow.variable}`}>
      <body>
        <div className="hud-shell">
          <header className="hud-topbar">
            <div className="hud-brand">
              DCS // Mission Control
              <small>single server · mission telemetry</small>
            </div>
            <nav className="hud-nav" aria-label="Primary">
              <Link href="/">Missions</Link>
              <Link href="/players">Players</Link>
            </nav>
          </header>
          {children}
        </div>
      </body>
    </html>
  );
}
