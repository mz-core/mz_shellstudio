const RESOURCE_NAME = /^[A-Za-z0-9_-]+$/
const CALLBACK_NAME = /^[A-Za-z0-9:_-]+$/

export const isPreview = typeof window.GetParentResourceName !== "function"

export async function postNui<TResult>(callbackName: string, payload: unknown = {}): Promise<TResult> {
  if (isPreview) return { ok: true } as TResult
  const resourceName = window.GetParentResourceName!()
  if (!RESOURCE_NAME.test(resourceName) || !CALLBACK_NAME.test(callbackName)) throw new Error("Callback NUI invalido")
  const controller = new AbortController()
  const timeout = window.setTimeout(() => controller.abort(), 8000)
  try {
    const response = await fetch(`https://${resourceName}/${callbackName}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })
    if (!response.ok) throw new Error(`NUI HTTP ${response.status}`)
    return (await response.json()) as TResult
  } finally {
    window.clearTimeout(timeout)
  }
}

declare global {
  interface Window { GetParentResourceName?: () => string }
}
