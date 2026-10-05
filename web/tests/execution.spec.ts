import { expect, test, type Page } from "@playwright/test"

async function hostFixture(page: Page, failFirstSend = false) {
  const calls: { method: string; params: Record<string, unknown> }[] = []
  let created = false
  let interrupted = false
  let sendAttempts = 0
  let model = "model-one"
  const conversation = { id: "host-conversation", nativeSessionID: "native-conversation", provider: "codex", providerInstanceID: "codex:/home/user/.codex",
    workspaceID: "/work/project", cwd: "/work/project", transcriptPath: "/home/user/.codex/sessions/session.jsonl", title: "Test conversation", connected: true }
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname
    if (path !== "/api/control") {
      await route.fulfill({ status: 401, contentType: "application/json", body: JSON.stringify({ error: "Authentication required" }) })
      return
    }
    expect(route.request().headers().authorization).toBe(`Bearer ${"a".repeat(64)}`)
    const request = route.request().postDataJSON() as { id: string; method: string; params: Record<string, unknown> }
    calls.push(request)
    let result: unknown
    switch (request.method) {
      case "host.info": result = { hostId: "test-host", providers: ["codex"], capabilities: ["conversation", "queue", "schedules"] }; break
      case "workspace.list": result = [{ id: "/work/project", path: "/work/project" }]; break
      case "conversation.list": result = created ? [conversation] : []; break
      case "schedule.list": result = []; break
      case "conversation.create": created = true; result = { conversation }; break
      case "conversation.model": model = String(request.params.text); result = { receipt: { accepted: true } }; break
      case "conversation.send":
        sendAttempts++
        if (failFirstSend && sendAttempts === 1) { await route.abort(); return }
        result = { receipt: { accepted: true, commandId: request.params.commandId } }; break
      case "conversation.interrupt": interrupted = true; result = { receipt: { accepted: true } }; break
      case "command.read": result = { status: "completed", result: { receipt: { accepted: true } } }; break
      case "conversation.read": result = {
        conversation, ready: true, connected: true, running: sendAttempts > 0 && !interrupted, queueHeld: false,
        actions: ["prompt", "steer", "cancel", "model"], queue: [], deliveries: [],
        controls: { models: [{ id: "model-one", name: "Model one" }, { id: "model-two", name: "Model two" }], selectedModelId: model,
          configOptions: [], pendingControlCommandIds: [], promptCapabilities: { image: false, audio: false, embeddedContext: true } },
        thread: { snapshotSequence: 1, messages: [], pendingRequests: [] },
        presentation: { conversation: { presentation: [], ephemeral: [], state: { pending_interactions: [] } } }
      }; break
      default: result = true
    }
    await route.fulfill({ contentType: "application/json", body: JSON.stringify({ id: request.id, result }) })
  })
  await page.goto("/?view=execution")
  await page.getByLabel("Execution pairing token").fill("a".repeat(64))
  await page.getByRole("button", { name: "Pair host", exact: true }).click()
  await page.getByRole("button", { name: "Create conversation", exact: true }).click()
  await expect(page.getByLabel("Message to agent")).toBeVisible()
  return calls
}

test("execution pairing works independently of history and configures the first send", async ({ page }) => {
  const calls = await hostFixture(page)
  expect(calls.filter(call => call.method === "conversation.send")).toHaveLength(0)
  await page.getByLabel("Execution model").selectOption("model-two")
  await expect(page.getByLabel("Execution model")).toHaveValue("model-two")
  await page.getByLabel("Message to agent").fill("Configured first prompt")
  await page.getByRole("button", { name: "Send", exact: true }).click()
  await expect.poll(() => calls.filter(call => call.method === "conversation.send").length).toBe(1)
  const send = calls.find(call => call.method === "conversation.send")!
  expect(send.params.hostId).toBe("test-host")
  expect(send.params.text).toBe("Configured first prompt")
  expect(typeof send.params.commandId).toBe("string")
  expect(typeof send.params.issuedAt).toBe("string")
  expect(calls.findIndex(call => call.method === "conversation.model")).toBeLessThan(calls.indexOf(send))
})

test("interrupted acknowledgement retains the exact outgoing request and retry identity", async ({ page }) => {
  const calls = await hostFixture(page, true)
  await page.getByLabel("Message to agent").fill("Do this once")
  await page.getByRole("button", { name: "Send", exact: true }).click()
  await expect(page.getByRole("button", { name: "Retry exact command" })).toBeVisible()
  await expect(page.getByLabel("Message to agent")).toHaveValue("Do this once")
  await expect(page.getByRole("button", { name: "Send", exact: true })).toBeDisabled()
  const saved = await page.evaluate(() => Object.keys(localStorage).filter(key => key.startsWith("memex-execution-outbox-v1:")).map(key => JSON.parse(localStorage.getItem(key)!)))
  expect(saved).toHaveLength(1)
  expect(saved[0].params.text).toBe("Do this once")
  await page.getByRole("button", { name: "Retry exact command" }).click()
  await expect.poll(() => calls.filter(call => call.method === "conversation.send").length).toBe(2)
  const attempts = calls.filter(call => call.method === "conversation.send")
  expect(attempts[1].params).toEqual(attempts[0].params)
  await expect(page.getByRole("button", { name: "Retry exact command" })).toHaveCount(0)
})

test("mobile viewport can operate an active conversation", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const calls = await hostFixture(page)
  await page.getByLabel("Message to agent").fill("Mobile prompt")
  await page.getByRole("button", { name: "Send", exact: true }).click()
  await expect(page.getByRole("button", { name: "Stop", exact: true })).toBeEnabled()
  await page.getByRole("button", { name: "Stop", exact: true }).click()
  await expect.poll(() => calls.some(call => call.method === "conversation.interrupt")).toBe(true)
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
})

test("retrying an uncertain send preserves newly attached draft context", async ({ page }) => {
  const calls = await hostFixture(page, true)
  await page.getByLabel("Message to agent").fill("Do this once")
  await page.getByRole("button", { name: "Send", exact: true }).click()
  await expect(page.getByRole("button", { name: "Retry exact command" })).toBeVisible()
  await page.locator('input[type="file"]').setInputFiles({ name: "context.txt", mimeType: "text/plain", buffer: Buffer.from("New draft context") })
  await expect(page.getByRole("button", { name: "context.txt ×" })).toBeVisible()
  await page.getByRole("button", { name: "Retry exact command" }).click()
  await expect.poll(() => calls.filter(call => call.method === "conversation.send").length).toBe(2)
  await expect(page.getByRole("button", { name: "Retry exact command" })).toHaveCount(0)
  await expect(page.getByLabel("Message to agent")).toHaveValue("Do this once")
  await expect(page.getByRole("button", { name: "context.txt ×" })).toBeVisible()
})
