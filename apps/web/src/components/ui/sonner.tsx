import { Toaster as Sonner, type ToasterProps } from "sonner"
import CircleCheckIcon from "lucide-react/dist/esm/icons/circle-check.mjs"
import InfoIcon from "lucide-react/dist/esm/icons/info.mjs"
import Loader2Icon from "lucide-react/dist/esm/icons/loader-2.mjs"
import OctagonXIcon from "lucide-react/dist/esm/icons/octagon-x.mjs"
import TriangleAlertIcon from "lucide-react/dist/esm/icons/triangle-alert.mjs"

const Toaster = ({ ...props }: ToasterProps) => {
  return (
    <Sonner
      theme="light"
      className="toaster group"
      icons={{
        success: (
          <CircleCheckIcon className="size-4" />
        ),
        info: (
          <InfoIcon className="size-4" />
        ),
        warning: (
          <TriangleAlertIcon className="size-4" />
        ),
        error: (
          <OctagonXIcon className="size-4" />
        ),
        loading: (
          <Loader2Icon className="size-4 animate-spin" />
        ),
      }}
      style={
        {
          "--normal-bg": "var(--popover)",
          "--normal-text": "var(--popover-foreground)",
          "--normal-border": "var(--border)",
          "--border-radius": "var(--radius)",
        } as React.CSSProperties
      }
      toastOptions={{
        classNames: {
          toast: "cn-toast",
        },
      }}
      {...props}
    />
  )
}

export { Toaster }
