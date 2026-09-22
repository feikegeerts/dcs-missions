import { defineConfig } from "drizzle-kit";

export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  migrations: {
    // Production uses the historical journal created during the initial
    // Neon backfill. Keep migrate pointed at that journal rather than
    // creating a second drizzle.__drizzle_migrations history.
    table: "drizzle-migrations",
    schema: "public",
  },
  dbCredentials: {
    url: process.env.DATABASE_URL_UNPOOLED ?? "",
  },
});
