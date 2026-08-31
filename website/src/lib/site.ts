/** Single place for every external link and download target the site points at. */
export const SITE = {
  /**
   * Every absolute URL the site emits derives from this: `metadataBase`, the
   * canonical, `og:url`, `og:image`, the sitemap and robots host.
   *
   * This is the apex, and it has to stay the apex. While it pointed at the
   * Vercel deployment the canonical on `codestatus.dev` named a different host
   * as the real page, which hands every signal the domain earns to a hostname
   * nobody is meant to link to. The `.vercel.app` deployment still answers, so
   * it should redirect here rather than serve the same page at a second URL.
   */
  url: "https://codestatus.dev",
  repo: "https://github.com/henriquegpb/codestatus",

  /**
   * Direct downloads rather than the release page.
   *
   * Each release workflow uploads its artifact twice — once versioned for the
   * record, once under the fixed name used here — because
   * `/releases/latest/download/<name>` needs a filename that does not change
   * with the version.
   */
  downloads: {
    macos: {
      label: "Download for macOS",
      icon: "/Apple.svg",
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.dmg",
      requirements: "macOS 14 or later",
    },
    windows: {
      label: "Download for Windows",
      icon: "/Windows.svg",
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus-Setup.exe",
      /**
       * Windows on Arm gets its own installer rather than being served an x64
       * one to emulate. It is also what a Windows VM on an Apple Silicon Mac
       * runs, which is how most of this app is going to be tested.
       */
      armUrl:
        "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus-Setup-arm64.exe",
      requirements: "Windows 10 or later",
      /**
       * Said on the page rather than discovered at the moment of installing.
       *
       * An unsigned Windows installer meets SmartScreen with a full-width blue
       * panel that says the app is unrecognised and hides the button that
       * continues anyway. Somebody who was not told to expect it reasonably
       * concludes the download is unsafe — so the page tells them, and the day
       * there is an Authenticode certificate this line comes out.
       */
      unsigned: true,
    },
  },

  /**
   * The latest published release, for structured data only — the download links
   * resolve to whatever is newest regardless. Bump it with the tag; a stale
   * value here misinforms crawlers rather than breaking anything.
   */
  version: "0.5.1",
  author: "Henrique Barone",
  license: "https://opensource.org/licenses/MIT",
} as const;

export type Platform = keyof typeof SITE.downloads;
