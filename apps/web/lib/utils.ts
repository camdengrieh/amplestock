// SPDX-License-Identifier: MIT

import {clsx, type ClassValue} from 'clsx'
import {twMerge} from 'tailwind-merge'

/** The shadcn class merger: `clsx` for conditionals, `tailwind-merge` for conflicting utilities. */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs))
}
