/**
 * A platform mark that takes the colour of the text beside it.
 *
 * The three logos in `public/` are single-path silhouettes carrying their own
 * fill — Apple ships white, Windows ships Microsoft blue. Rendered as images
 * they would be wrong on at least one of our two buttons every time: white
 * vanishes on the green primary, blue fights it.
 *
 * So the file is used as a mask rather than as an image. The shape comes from
 * the SVG and the colour from `currentColor`, which means one asset works on
 * the green button, the black one, and whatever a future variant looks like,
 * without a second copy of each logo or a build step to inline them.
 *
 * The size comes from the caller and is not defaulted here, because `contain`
 * fits a mask to its longest side: a square logo fills the box and a tall one
 * does not, so the three marks need different boxes to look like one size. A
 * `size-4` baked in and then overridden would be a Tailwind conflict decided by
 * the order of the generated stylesheet rather than by the caller. See the
 * `iconClass` on each entry in `site.ts`.
 */
export function PlatformIcon({
  src,
  className,
}: {
  src: string;
  className: string;
}) {
  return (
    <span
      aria-hidden
      className={`inline-block shrink-0 bg-current ${className}`}
      style={{
        maskImage: `url(${src})`,
        WebkitMaskImage: `url(${src})`,
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}
