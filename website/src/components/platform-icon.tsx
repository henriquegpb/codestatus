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
 */
export function PlatformIcon({
  src,
  className = "",
}: {
  src: string;
  className?: string;
}) {
  return (
    <span
      aria-hidden
      className={`inline-block size-4 shrink-0 bg-current ${className}`}
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
