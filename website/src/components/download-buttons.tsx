"use client";

import Image from "next/image";
import { useSyncExternalStore } from "react";
import githubMark from "../../public/GitHub.svg";
import { IconSwapButton } from "@/components/icon-swap-button";
import { PlatformIcon } from "@/components/platform-icon";
import { SITE, type Platform } from "@/lib/site";

/**
 * Read through useSyncExternalStore rather than an effect that calls setState.
 *
 * The platform is exactly what that hook is for: a value owned outside React
 * that the server cannot see. It also gets the hydration behaviour right for
 * free — the server snapshot is what renders in HTML, the client snapshot
 * replaces it on hydration, and React does not warn about the mismatch it
 * would otherwise flag.
 */
const subscribe = () => () => {};

function detectPlatform(): Platform {
  if (typeof navigator === "undefined") return "macos";

  // userAgentData is the non-deprecated route and is exact where it exists.
  // The `platform` string is the fallback for Safari and Firefox, which do not
  // implement it, and it is enough: we only need to tell two families apart.
  const hinted = (
    navigator as Navigator & { userAgentData?: { platform?: string } }
  ).userAgentData?.platform;
  const raw = hinted || navigator.platform || navigator.userAgent;
  return /win/i.test(raw) ? "windows" : "macos";
}

/**
 * The download call to action, pointed at the machine reading the page.
 *
 * There are two builds now, and offering both with equal weight makes everyone
 * read two labels to find their own. So the visitor's platform becomes the
 * primary button and the other one stays available beside it — nothing is
 * hidden, but nobody has to choose.
 *
 * Server-rendered as macOS, corrected on mount. That order is deliberate rather
 * than arbitrary: macOS is the reference build, it is the larger share of this
 * audience, and a Windows visitor sees the swap inside the first frame while a
 * crawler — which runs no JavaScript — indexes a page whose primary link
 * matches the `downloadUrl` in the structured data.
 *
 * Both buttons are always mounted and in the same order in the DOM. Only the
 * variant moves, so the correction cannot reflow the hero.
 */
export function DownloadButtons({
  align = "start",
  showRequirements = true,
}: {
  align?: "start" | "center";
  showRequirements?: boolean;
}) {
  // The subscription never fires: nobody changes operating system mid-page.
  const platform = useSyncExternalStore(subscribe, detectPlatform, () => "macos" as Platform);

  const isWindows = platform === "windows";
  const { macos, windows } = SITE.downloads;
  // The visitor's own platform leads; the other follows. A third entry here is
  // all Linux will need, the day there is a Linux build.
  const mine = isWindows ? windows : macos;
  const other = isWindows ? macos : windows;

  return (
    <div className={align === "center" ? "flex flex-col items-center" : ""}>
      <div
        className={`flex flex-wrap items-center gap-4 ${
          align === "center" ? "justify-center" : ""
        }`}
      >
        <IconSwapButton
          href={mine.url}
          label={mine.label}
          variant="primary"
          icon={<PlatformIcon src={mine.icon} />}
        />
        <IconSwapButton
          href={other.url}
          label={other.label}
          icon={<PlatformIcon src={other.icon} />}
        />
        <IconSwapButton
          href={SITE.repo}
          label="View source"
          icon={<Image src={githubMark} alt="" width={16} height={16} aria-hidden />}
        />
      </div>

      {showRequirements && (
        <p
          className={`mt-4 font-mono text-xs leading-relaxed text-muted ${
            align === "center" ? "text-center" : ""
          }`}
        >
          {isWindows ? windows.requirements : macos.requirements}
          {isWindows && (
            <>
              {" · "}
              <a
                className="underline decoration-line underline-offset-4 transition-colors hover:text-foreground"
                href={windows.armUrl}
              >
                Arm build
              </a>
              {windows.unsigned && (
                <>
                  <br />
                  The Windows installer is not signed yet, so SmartScreen will
                  warn once. More info → Run anyway.
                </>
              )}
            </>
          )}
        </p>
      )}
    </div>
  );
}
