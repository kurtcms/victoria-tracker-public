import { createHandler } from "./handler.ts";
Deno.serve(createHandler({
  supabaseURL: Deno.env.get("SUPABASE_URL") ?? "",
  supabaseKey: Deno.env.get("VT_SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "",
  openAIKey: Deno.env.get("OPENAI_API_KEY") ?? "",
  model: Deno.env.get("OPENAI_MODEL") ?? "gpt-4.1-mini",
}));
