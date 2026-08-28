declare module "lucide-react/dist/esm/icons/*.mjs" {
  import type { ForwardRefExoticComponent, RefAttributes, SVGProps } from "react";

  type DirectLucideProps = SVGProps<SVGSVGElement> & {
    size?: number | string;
    absoluteStrokeWidth?: boolean;
  };

  const Icon: ForwardRefExoticComponent<DirectLucideProps & RefAttributes<SVGSVGElement>>;
  export default Icon;
}
