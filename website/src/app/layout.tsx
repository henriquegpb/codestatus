import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { Analytics } from "@vercel/analytics/next";
import "./globals.css";
import { SITE } from "@/lib/site";
import { SiteBackground } from "@/components/site-background";
import { StructuredData } from "@/components/structured-data";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

/*
 * Two registers, deliberately.
 *
 * The `<title>` and description are written in the words someone actually types
 * or asks — "track Claude Code sessions", "notify when Codex finishes" — because
 * that is the only text a search engine or an assistant sees before deciding
 * whether this page answers the question. "A native macOS presence layer for
 * coding agents" is a good line and describes nothing anybody searches for.
 *
 * The social cards keep the brand voice. By the time someone sees one of those
 * they arrived through a person, not a query.
 */
export const metadata: Metadata = {
  metadataBase: new URL(SITE.url),
  applicationName: "CodeStatus",
  title: "CodeStatus - Track Claude Code & Codex sessions on macOS",
  description:
    "Free macOS menu bar app that tracks every Claude Code and Codex session and tells you the moment one finishes or needs you. Open source, no telemetry.",
  keywords: [
    "Claude Code notifications",
    "Codex notifications",
    "AI coding agent monitor",
    "track AI agent sessions",
    "coding agent status macOS",
    "notify when Claude Code finishes",
    "run multiple coding agents",
    "AI agent session tracker",
    "macOS menu bar developer tool",
    "Claude Code hooks",
    "Codex hooks",
  ],
  authors: [{ name: SITE.author }],
  creator: SITE.author,
  alternates: { canonical: SITE.url },
  openGraph: {
    title: "CodeStatus — Stop watching AI work",
    description:
      "A native macOS presence layer for coding agents. Know which Claude Code and Codex sessions are busy, free, or waiting for you — without tabbing between terminals.",
    url: SITE.url,
    siteName: "CodeStatus",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "CodeStatus — Stop watching AI work",
    description:
      "A native macOS presence layer for coding agents. Busy, free, or needs you — in your menu bar.",
  },
};

/**
 * What a machine reads instead of the prose.
 *
 * An assistant asked "is there something that tells me when my coding agent is
 * done" has to answer from whatever it can parse with confidence. Marketing
 * copy is not that; this is. Every claim here is one the page also makes in
 * words, which is both a guideline and the only way it stays true.
 */
const SOFTWARE_SCHEMA = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "CodeStatus",
  applicationCategory: "DeveloperApplication",
  operatingSystem: "macOS 14 or later",
  url: SITE.url,
  downloadUrl: SITE.download,
  softwareVersion: SITE.version,
  codeRepository: SITE.repo,
  license: SITE.license,
  isAccessibleForFree: true,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  author: { "@type": "Person", name: SITE.author },
  description:
    "A macOS menu bar app that tracks every Claude Code and Codex session running on your Mac and notifies you when one finishes, needs approval, or is waiting for input. State comes from the agents' own lifecycle hooks rather than from CPU usage, so a session is never guessed at.",
  featureList: [
    "Tracks Claude Code and Codex sessions in the macOS menu bar",
    "Notifies you when an agent finishes a turn",
    "Notifies you when an agent needs approval or input",
    "Shows busy, free, and needs-you counts at a glance",
    "Click a session to jump back to its terminal tab or VS Code workspace",
    "Reads state from official agent lifecycle hooks, never from CPU",
    "No account, no server, and no telemetry",
  ],
} as const;


// The identity is a black plate; the site does not offer a light theme, so the
// browser is told that outright rather than left to guess from the CSS.
export const viewport: Viewport = {
  colorScheme: "dark",
  themeColor: "#000000",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="relative min-h-full flex flex-col">
        <StructuredData schema={SOFTWARE_SCHEMA} />
        <SiteBackground />
        {children}
        {/*
         * Page views and nothing else. The app itself ships no telemetry and the
         * page says so in as many words; that promise is about what CodeStatus
         * does on your Mac, not about whether the marketing site counts visits.
         */}
        <Analytics />
      </body>
    </html>
  );
}
