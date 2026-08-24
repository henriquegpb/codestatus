import type { MetadataRoute } from "next";
import { SITE } from "@/lib/site";

/**
 * One page, so this is nearly a formality — but it is the file crawlers ask for
 * by name, and `robots.txt` now points at it. A 404 there is a small, avoidable
 * signal that nobody is maintaining the site.
 *
 * `lastModified` is read at build time, which is the honest answer: the page is
 * static, so the build is the last time it could have changed.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: SITE.url,
      lastModified: new Date(),
      changeFrequency: "monthly",
      priority: 1,
    },
  ];
}
