/** Single place for every external link and download target the site points at. */
export const SITE = {
  /**
   * Every absolute URL the site emits derives from this: `metadataBase`, the
   * canonical, `og:url`, `og:image`, the sitemap and robots host.
   *
   * It points at the Vercel deployment rather than at `codestatus.app` because
   * that domain is still parked — it serves a "Coming Soon" page over HTTP and
   * no valid certificate over HTTPS. A share card whose `og:image` resolves
   * there is an unreachable image, so link previews come back blank. Point this
   * back at the apex the moment the domain is connected; nothing else changes.
   */
  url: "https://codestatus-hb.vercel.app",
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
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.dmg",
      requirements: "macOS 14 or later",
    },
    windows: {
      label: "Download for Windows",
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
  version: "0.1.0",
  author: "Henrique Barone",
  license: "https://opensource.org/licenses/MIT",
} as const;

export type Platform = keyof typeof SITE.downloads;
