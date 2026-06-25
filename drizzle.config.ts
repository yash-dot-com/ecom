import { defineConfig } from "drizzle-kit"
import dotenv from "dotenv"

dotenv.config({ path: ".env" })

export default defineConfig({
  schema: "./src/database/schema",
  out: "./src/database/migration",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL
  }
})