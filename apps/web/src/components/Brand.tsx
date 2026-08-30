type BrandProps = {
  compact?: boolean;
  light?: boolean;
};

export function Brand({ compact = false, light = false }: BrandProps) {
  return (
    <a className={`brand ${light ? "brand--light" : ""}`} href="#top" aria-label="Firstless home">
      <span className="brand__mark">
        <img src="/brand/firstless-mark.svg" alt="" />
      </span>
      {!compact && <span className="brand__name">firstless</span>}
    </a>
  );
}
