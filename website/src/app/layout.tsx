import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { SITE } from "@/lib/site";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL(SITE.url),
  title: "CodeStatus — Stop watching AI work",
  description:
    "A native macOS presence layer for coding agents. Start several, keep working, and come back only when one is actually done or actually needs you.",
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
      "A native macOS presence layer for coding agents. Busy, free, or needs you — around the notch.",
  },
};

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
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
