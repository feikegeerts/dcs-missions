import Link from "next/link";

import { AutoRefresh } from "@/components/auto-refresh";
import { CollectorHealth } from "@/components/collector-health";
import { NeonTelemetryStore } from "@/telemetry/store";

export const dynamic = "force-dynamic";

export default async function CollectorHealthPage() {
  const now = new Date();
  const store = new NeonTelemetryStore();
  const record = (await store.getCollectorHealth())[0] ?? null;

  return (
    <main>
      <AutoRefresh displayStatus={null} renderToken={now.getTime()} />
      <p className="hud-crumbs">
        <Link href="/">Missions</Link>
        <span className="sep">/</span>
        <span>Collector health</span>
      </p>
      <h1 className="hud-title">Collector health</h1>
      <p className="hud-subtitle">
        Delivery and ingestion status for the telemetry collector.
      </p>

      <div className="hud-grid" style={{ marginTop: "1rem" }}>
        <CollectorHealth record={record} serverTime={now} />
      </div>
    </main>
  );
}
