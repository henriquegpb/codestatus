/** Single place for every external link and download target the site points at. */
export const SITE = {
  url: "https://codestatus.app",
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
