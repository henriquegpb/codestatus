import type { MetadataRoute } from "next";
import { SITE } from "@/lib/site";

/**
 * The AI crawlers are named explicitly rather than left to the wildcard.
 *
 * Not because they need the permission — a bare `Allow: /` already covers them —
 * but because the default many sites now ship blocks them, and several of these
 * agents check for their own user-agent before falling back. Naming them states
 * the intent: this page exists to be read by the assistants people ask "how do
 * I get told when my coding agent finishes", and there is nothing here worth
 * withholding from them.
 */
const AI_CRAWLERS = [
  "GPTBot",
  "OAI-SearchBot",
  "ChatGPT-User",
  "ClaudeBot",
  "Claude-User",
  "Claude-SearchBot",
  "anthropic-ai",
  "PerplexityBot",
  "Perplexity-User",
  "Google-Extended",
  "Applebot-Extended",
  "CCBot",
  "cohere-ai",
  "Meta-ExternalAgent",
  "Amazonbot",
  "DuckAssistBot",
  "Bytespider",
  "YouBot",
];

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      { userAgent: "*", allow: "/" },
      ...AI_CRAWLERS.map((userAgent) => ({ userAgent, allow: "/" })),
    ],
    sitemap: `${SITE.url}/sitemap.xml`,
    host: SITE.url,
  };
}
