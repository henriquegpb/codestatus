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
  // implement it, and it is enough: we only need to tell three families apart.
  const hinted = (
    navigator as Navigator & { userAgentData?: { platform?: string } }
  ).userAgentData?.platform;
  const raw = hinted || navigator.platform || navigator.userAgent;

  if (/win/i.test(raw)) return "windows";
  // Ordered after Windows and before the macOS default, and both halves of that
  // matter. "Win" appears in no Linux UA, so Windows can go first safely — but
  // Android reports "Linux" in every user agent string it sends, and an Android
  // visitor offered a .deb is being told something false. Excluding it leaves
  // them on the macOS default, which is wrong too, but wrong in the way every
  // unrecognised platform already is rather than confidently wrong.
  if (/linux|x11|bsd/i.test(raw) && !/android/i.test(raw)) return "linux";
  return "macos";
}

/** Every platform but the visitor's own, in a fixed order. */
const ORDER: Platform[] = ["macos", "windows", "linux"];

/**
 * The download call to action, pointed at the machine reading the page.
 *
 * There are three builds now, and offering them with equal weight makes
 * everyone read three labels to find their own. So the visitor's platform
 * becomes the primary button and the others stay available beside it — nothing
 * is hidden, but nobody has to choose.
 *
 * Server-rendered as macOS, corrected on mount. That order is deliberate rather
 * than arbitrary: macOS is the reference build, it is the larger share of this
 * audience, and a Windows or Linux visitor sees the swap inside the first frame
 * while a crawler — which runs no JavaScript — indexes a page whose primary
 * link matches the `downloadUrl` in the structured data.
 *
 * Every button is always mounted, and the others keep their relative order.
 * Only the variant moves, so the correction cannot reflow the hero.
 *
 * The requirements line reads entirely from the data. When Linux arrived it
 * needed a second artifact and a caveat of its own, and the shape that already
 * existed for the Windows Arm build and the SmartScreen note covered both — so
 * a third platform is an entry in `site.ts` rather than a third branch here.
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

  const mine = SITE.downloads[platform];
  const others = ORDER.filter((key) => key !== platform).map((key) => SITE.downloads[key]);

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
        {others.map((build) => (
          <IconSwapButton
            key={build.url}
            href={build.url}
            label={build.label}
            icon={<PlatformIcon src={build.icon} />}
          />
        ))}
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
          {mine.requirements}
          {mine.alt && (
            <>
              {" · "}
              <a
                className="underline decoration-line underline-offset-4 transition-colors hover:text-foreground"
                href={mine.alt.url}
              >
                {mine.alt.label}
              </a>
            </>
          )}
          {mine.caveat && (
            <>
              <br />
              {mine.caveat}
            </>
          )}
        </p>
      )}
    </div>
  );
}
