import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "DCS Telemetry",
  description: "Raw DCS mission telemetry",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body style={{ fontFamily: "sans-serif", margin: "2rem" }}>
        {children}
      </body>
    </html>
  );
}
