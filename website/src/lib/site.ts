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
    /**
     * Every platform carries the same four optional fields even when it has
     * nothing to put in them, so the buttons can render one shape instead of
     * branching per platform. macOS is the build with no second artifact and
     * nothing to warn about — it is signed, notarised, and one file.
     */
    macos: {
      label: "Download for macOS",
      icon: "/Apple.svg",
      iconClass: "size-4",
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.dmg",
      requirements: "macOS 14 or later",
      alt: null,
      caveat: null,
    },
    windows: {
      label: "Download for Windows",
      icon: "/Windows.svg",
      iconClass: "size-4",
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus-Setup.exe",
      requirements: "Windows 10 or later",
      /**
       * Windows on Arm gets its own installer rather than being served an x64
       * one to emulate. It is also what a Windows VM on an Apple Silicon Mac
       * runs, which is how most of this app is going to be tested.
       */
      alt: {
        label: "Arm build",
        url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus-Setup-arm64.exe",
      },
      /**
       * Said on the page rather than discovered at the moment of installing.
       *
       * An unsigned Windows installer meets SmartScreen with a full-width blue
       * panel that says the app is unrecognised and hides the button that
       * continues anyway. Somebody who was not told to expect it reasonably
       * concludes the download is unsafe — so the page tells them, and the day
       * there is an Authenticode certificate this line comes out.
       */
      caveat:
        "The Windows installer is not signed yet, so SmartScreen will warn once. More info → Run anyway.",
    },
    linux: {
      label: "Download for Linux",
      icon: "/Linux.svg",
      /**
       * Larger than the other two, to look the same size.
       *
       * The masks are fitted with `contain`, so a logo only fills the box it is
       * given if it is square. Windows is `0 0 4875 4875` and does. Tux is
       * `0 0 266 312`, so at a 16px box he is fitted to the height and comes
       * out 13.6px wide — and a tapered penguin already reads lighter than four
       * solid squares. This is the optical correction, and it belongs next to
       * the asset that needs it rather than in the component that lays it out.
       */
      iconClass: "size-[1.15rem]",
      url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.deb",
      requirements: "Debian, Ubuntu, Mint, Pop!_OS",
      /** Everything that is not Debian-derived. */
      alt: {
        label: ".rpm for Fedora and openSUSE",
        url: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.rpm",
      },
      /**
       * The one thing a Linux visitor has to know before downloading, rather
       * than after installing and seeing no icon.
       *
       * GNOME removed the system tray from its shell in 3.26 and never restored
       * it. Ubuntu ships the AppIndicator extension enabled so the icon appears;
       * on Fedora and vanilla GNOME it does not, and there is no error to see —
       * the app is running correctly and looks like it failed to start. Every
       * other desktop has a tray of its own.
       */
      caveat:
        "On Fedora or vanilla GNOME, install gnome-shell-extension-appindicator first — GNOME's shell has no tray of its own and the icon will not appear. Ubuntu, KDE, XFCE, Cinnamon and MATE need nothing.",
    },
  },

  /**
   * The latest published release, for structured data only — the download links
   * resolve to whatever is newest regardless. Bump it with the tag; a stale
   * value here misinforms crawlers rather than breaking anything.
   */
  version: "0.6.1",
  author: "Henrique Barone",
  license: "https://opensource.org/licenses/MIT",
} as const;

export type Platform = keyof typeof SITE.downloads;
