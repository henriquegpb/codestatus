# CodeStatus website

The marketing and download site for CodeStatus. Next.js (App Router) + Tailwind,
deployed on Vercel with this directory as the project root.

```sh
npm install
npm run dev     # http://localhost:3000
npm run build   # what CI and Vercel run
npm run lint
```

Every page prerenders to static HTML — there is no server code, no API route,
and no runtime data fetching, which matches the product's own "no network" claim.

## Where things live

- `src/app/page.tsx` — the whole landing page, section by section.
- `src/lib/site.ts` — every external link, including the download target. Change
  release URLs here, not inline.
- `src/components/` — `hud-preview` (the animated HUD in the hero),
  `capability-matrix`, `section`.

## The HUD preview

`hud-preview.tsx` is the only client component on the page: a timeline of frames
that a `setTimeout` steps through. Sessions arrive at the top and leave from the
bottom, states change, and a macOS-style notification fires when one finishes.

Four constraints it has to keep:

- **The list always holds exactly `SEATS` rows** (three — the hero has to fit
  one screen). A leaving row keeps its slot until the arriving one takes it, so
  the panel never changes height and the page below it never jumps.
- **Rows move by FLIP, never by teleporting.** `SessionList` measures each row
  before the update, then transforms it back and releases it, so the rows a
  swap displaces slide into their new slots.
- **Frames are a fixed rotation, never randomised.** The product's claim is that
  state changes are events; a random shuffle would be demonstrating the
  opposite. A row takes `SEATS` cycles to walk from the top of the list to the
  bottom and out, so a cast longer than that guarantees the session arriving is
  never one already on screen — and the list returns to the opening frame
  exactly, so the loop has no seam. Shrinking the cast to `SEATS` or fewer puts
  a session on screen twice.
- **It stops when nobody is watching.** An `IntersectionObserver` pauses the
  timer off-screen, and `prefers-reduced-motion` leaves it on the first frame
  with every animation off.

The notification is portalled to `document.body` and fixed to the top right of
the *window*, not the card, because that is where macOS puts it.

Icons are Lucide. Decorative ones take the brand green; the capability matrix
uses the state colours instead, because a red cross has to read as a limitation
at a glance.
- `src/app/globals.css` — the palette, as CSS variables exposed to Tailwind
  through `@theme inline`.
- `public/wordmark.svg`, `public/mark.svg` — the logo. `src/app/icon.svg` is a
  copy of the mark; keep them in sync if the mark changes.
- `src/app/opengraph-image.tsx` — the share card, drawn at build time.

## The identity

Three elements: a black plate, thin white type, one glowing green dot
(`#4EE000`). Everything on the page follows from that.

- **Dark only, on purpose.** The logo SVGs carry their own black background
  rect, so `--background` is pure `#000000` and the plate disappears into the
  page. There is no light theme; adding one means re-cutting the logo with a
  transparent background first.
- **The green is the accent *and* the `free` state.** Same colour, same dot the
  HUD shows — that is the point, not a coincidence to be tidied away.
- **The bloom is a brand element.** `.dot-glow` reproduces the glow from the
  mark and is used on every state dot, so the logo and the HUD preview read as
  the same object.
- **Headings are light-weight.** The wordmark is thin; `font-semibold`
  headings fight it.

## Keeping copy honest

The page repeats the claims in the root `README.md` — the privacy guarantee, the
capability matrix, the three design choices. When those change in the product,
change them here in the same pull request. The matrix in particular states
limitations deliberately; do not quietly upgrade an *unverified* cell.

`AGENTS.md` and `CLAUDE.md` are generated and rewritten by `next dev`.
