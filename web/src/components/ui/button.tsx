import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "cn"
import { Slot } from "radix-ui"

const buttonVariants = cva("mz-button", {
  variants: {
    variant: { default: "mz-button--default", outline: "mz-button--outline", ghost: "mz-button--ghost", destructive: "mz-button--destructive" },
    size: { default: "mz-button--md", sm: "mz-button--sm", icon: "mz-button--icon" },
  },
  defaultVariants: { variant: "default", size: "default" },
})

function Button({ className, variant, size, asChild = false, ...props }:
  React.ComponentProps<"button"> & VariantProps<typeof buttonVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot.Root : "button"
  return <Comp data-slot="button" className={cn(buttonVariants({ variant, size, className }))} {...props} />
}

export { Button, buttonVariants }
