/** Single place for every external link and download target the site points at. */
export const SITE = {
  url: "https://codestatus.app",
  repo: "https://github.com/henriquegpb/codestatus",
  /**
   * Points at the release page rather than an asset, because the DMG that
   * `scripts/make-dmg.sh` produces carries its version in the filename
   * (`CodeStatus-0.1.0.dmg`), so there is no stable
   * `/releases/latest/download/<name>` URL to link to. If the release workflow
   * ever uploads an unversioned copy as well, switch this to that direct link.
   */
  download: "https://github.com/henriquegpb/codestatus/releases/latest",
  requirements: "macOS 14 or later",
} as const;
