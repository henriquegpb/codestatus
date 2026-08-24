/**
 * Emits one JSON-LD block.
 *
 * Kept as a component so every schema on the site is serialised the same way,
 * and so each one can live next to the markup it describes — structured data
 * that drifts from the visible page is worse than none, because it is both a
 * guideline violation and a lie a machine will repeat confidently.
 */
export function StructuredData({ schema }: { schema: object }) {
  return (
    <script
      type="application/ld+json"
      // Authored in this repository, never user input. This is the documented
      // way to emit JSON-LD from the App Router.
      dangerouslySetInnerHTML={{ __html: JSON.stringify(schema) }}
    />
  );
}
