import { useEffect, useRef, type RefObject } from 'react'

const focusableSelector = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

let fallbackFocus: HTMLElement | null = null

export function useDialogFocus(
  dialogRef: RefObject<HTMLElement | null>,
  onClose: () => void,
  initialFocusRef?: RefObject<HTMLElement | null>,
) {
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose
  useEffect(() => {
    const dialog = dialogRef.current
    if (!dialog) return

    const activeElement = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null
    const previouslyFocused = activeElement ?? fallbackFocus
    const underlyingDialog = activeElement?.closest<HTMLElement>('[role="dialog"], [role="alertdialog"]')
    if (activeElement && !activeElement.closest('[role="dialog"]')) {
      fallbackFocus = activeElement
    }
    const layer = dialog.parentElement
    const siblings = layer?.parentElement
      ? Array.from(layer.parentElement.children).filter(
          (element): element is HTMLElement => element instanceof HTMLElement && element !== layer,
        )
      : []
    const previousInert = siblings.map((element) => element.inert)
    siblings.forEach((element) => { element.inert = true })

    const focusableElements = () => Array.from(
      dialog.querySelectorAll<HTMLElement>(focusableSelector),
    ).filter((element) => !element.hidden && element.getAttribute('aria-hidden') !== 'true')

    if (!dialog.contains(document.activeElement)) {
      const initialFocus = initialFocusRef?.current ?? focusableElements()[0]
      if (initialFocus) initialFocus.focus()
      else dialog.focus()
    }

    const handleKeyDown = (event: KeyboardEvent) => {
      if (dialog.closest('[inert]')) return
      if (event.key === 'Escape') {
        event.preventDefault()
        onCloseRef.current()
        return
      }
      if (event.key !== 'Tab') return

      const focusable = focusableElements()
      if (!focusable.length) {
        event.preventDefault()
        dialog.focus()
        return
      }
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', handleKeyDown)
    return () => {
      document.removeEventListener('keydown', handleKeyDown)
      siblings.forEach((element, index) => { element.inert = previousInert[index] })
      const underlyingFocus = underlyingDialog?.isConnected
        ? underlyingDialog.querySelector<HTMLElement>(focusableSelector)
        : null
      const restoreTarget = previouslyFocused?.isConnected
        ? previouslyFocused
        : underlyingFocus ?? fallbackFocus
      restoreTarget?.focus()
    }
  }, [dialogRef, initialFocusRef])
}
