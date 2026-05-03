# OpenClaw demo asset — recording guide

This is the canonical recipe for capturing the v1 round-trip demo: Doey
notifies a Discord channel, the operator replies, Doey ingests the
reply and continues the task. The recording is shipped (or linked) as
the headline artifact for the OpenClaw integration.

The demo is **not** auto-recorded. This document tells the operator what
to set up, what to capture, and what the result must look like.
Recording itself stays in the operator's hands so we don't ship binary
assets through CI.

## What we're showing

> "Doey running locally, asking a question via Discord. The user replies
> in Discord. Doey picks up the reply seconds later and resumes work."

The point of the asset is to make the round-trip feel ordinary — one
channel, one reply, no thread tree, no @-mention dance. The default UX
must look like a normal chat.

## Capture target — "default reply UX, no reply-chain"

The demo MUST show the default correlation path:

- **Single open task → flat reply.** Doey posts the question as a fresh
  message in the bound channel. The operator replies by typing in the
  channel — **no Discord native "Reply" feature, no thread**. The bridge
  correlates by the permissive 1-open-thread rule (see
  `oc_correlation_resolve` in `shell/doey-openclaw.sh`) and resolves the
  thread on first reply.
- **No `message_reference` adornment.** The reply must be a plain
  message in the channel, with no quoted context bubble above it.
  Discord shows reply-chain UI only when `message_reference` is set;
  Doey's outbound path leaves it unset by default.
- **No thread fan-out.** Discord threads are explicitly out of scope for
  the v1 demo. Reply-chain (the per-message `message_reference` link) is
  the fallback for the 2+ open task case and is documented in
  `docs/openclaw-integration.md` — but it is **not** what we showcase.

If the recording shows a "▸ replying to ..." quoted bubble above the
operator's message, re-record. That is the reply-chain path and it is
the wrong story for the headline asset.

## Pre-flight checklist

1. Fresh checkout, dependencies built:
   ```
   cd tui && go build ./...
   ```
2. OpenClaw daemon running on `http://localhost:18789` and reachable.
3. Run `/doey-openclaw-connect` inside the Doey session and bind the
   project to a **dedicated empty Discord channel**. Use a private
   server you own, not a real workspace — the recording will be public.
4. Confirm the bridge is alive:
   ```
   doey openclaw status   # bridge=running pid=<n>
   doey openclaw doctor   # all green or warn-only
   ```
5. Confirm fresh-install hygiene by running once with no binding (the
   demo is about a configured project — but the surrounding repo must
   stay invariant-clean before you bind):
   ```
   tests/openclaw-fresh-install.sh
   ```
6. Pick a screen-recording tool that records the Doey terminal pane and
   the Discord channel side-by-side. Native macOS QuickTime + a tiled
   Discord window works; on Linux, `peek` or `OBS` are fine.

## Demo script

Run all of the following in a clean session. Keep the Discord pane
visible the whole time.

1. **Frame the shot.** Doey terminal on the left, Discord channel on
   the right. The dashboard pane (`0.0`) and the Boss pane (`0.1`)
   should both be visible.
2. **Prompt Boss with a question that needs an external answer.** A
   stable script:
   > Boss: "Pick a project name for the new repo — I want it user-driven,
   > not auto-generated."
3. **Boss posts the question to Discord** via the OpenClaw outbound
   path. The viewer sees a single new message arrive in the channel —
   no embed, no thread, no quote bubble.
4. **Operator replies in Discord** by typing the answer directly in the
   channel input (NOT via the right-click "Reply" affordance):
   > Operator: "let's call it `lighthouse`"
5. **Doey ingests the reply.** The bridge picks it up on the next poll
   (≤ 25s long-poll window, typically ≤ 1s in practice). The Boss pane
   shows the reply being unwrapped from its `BEGIN/END nonce=...` frame
   and pasted into the prompt. Boss continues the task using the
   answer.
6. **Show that the loop closed.** The dashboard pane reflects task
   status changing. No second message goes back to Discord — single
   round-trip is enough for the asset.

Total runtime target: 30-45 seconds. If it's longer, trim the framing
and pre-buffer the Boss prompt so the viewer hits "send" inside the
recording window.

## Anti-patterns — re-record if you see any of these

- A "▸ Replying to ..." bubble above the operator's reply (this is the
  reply-chain UX).
- The reply lands in a thread instead of the channel root.
- A second outbound message to Discord echoing or summarizing the
  reply. v1 is one-shot — the operator's reply ends the round-trip.
- Visible secrets: gateway token, HMAC secret, webhook URL, or any
  `cred_hash` line. Crop these out or use placeholder values before
  recording.
- Desktop notification banners from unrelated apps.

## Output format and where it lives

- **Format:** `.mp4` or `.gif`, 1080p or higher source res, ≤ 4 MB
  asset. Down-convert if needed.
- **Frame rate:** 24-30 fps for video, 12-15 fps for GIF.
- **Naming:** `openclaw-roundtrip-demo.<ext>`.
- **Location:** Keep the binary OUT of the repo. Upload to the
  project's release/asset store and link from `README.md` and
  `docs/openclaw-integration.md`. We do not ship media through git.

## Privacy pass before publishing

- Scrub the channel name if it leaks workspace context.
- Confirm the bound user id, project path, and any token/secret are
  not visible in the dashboard or `doey openclaw status` output.
- If the `bound_user_ids=` line is shown, mask it.

## Re-recording cadence

Re-record on:

- Any change to the default reply UX (e.g., we start setting
  `message_reference` by default — that would be a v2 decision).
- Any change to the dashboard layout or Boss pane chrome that would
  make the asset stale.
- A new minimum daemon version that changes the on-screen `bound_at`
  or version footer.

When re-recording, replace the asset in place and update the link only
— don't keep historical versions in the repo or in `docs/`.
