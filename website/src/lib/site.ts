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
   * A direct download rather than the release page. The release workflow
   * uploads the signed image twice — once as `CodeStatus-<version>.dmg` for the
   * record, once under this fixed name — because
   * `/releases/latest/download/<name>` needs a filename that does not change
   * with the version.
   */
  download: "https://github.com/henriquegpb/codestatus/releases/latest/download/CodeStatus.dmg",
  requirements: "macOS 14 or later",
  /**
   * The latest published release, for structured data only — the download link
   * resolves to whatever is newest regardless. Bump it with the tag; a stale
   * value here misinforms crawlers rather than breaking anything.
   */
  version: "0.1.0",
  author: "Henrique Barone",
  license: "https://opensource.org/licenses/MIT",
} as const;
