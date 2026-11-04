## Problem

- A user transferring a large file lost the whole transfer if the page refreshed, the tab closed or the browser crashed. The "Transfer not finished" card could only be dismissed, so they had to start again from the first byte.
- The server half already keeps the session for 24 h and exposes a call that lists the parts it holds, but the client never used it.

## Fix

- **Save on start**: when a transfer starts, the page writes the transfer id, file name, size and last-modified time to local storage, keyed per account. It holds no file bytes. The record goes away on success, cancel or failure, and is kept 7 days at most.
- **Resume flow**: the "Transfer not finished" card offers **Resume transfer**. The user re-picks the file; the page refuses a file whose name, size or last-modified time differs. Then it replays the start call with the saved id, lists held parts, requests URLs for the missing parts only, and completes with every part tag.
- Worked example: a 3-part transfer of `sample.bin` dies after parts 1 and 3 land.

  ```text
  refresh -> card for item 901: "Transfer not finished" [Resume transfer]
  user re-picks sample.bin -> name/size/lastModified match saved record
  POST start {client_transfer_id: saved}  -> 200 idempotent, same session
  GET  items/901/parts                    -> parts [1, 3]
  POST urls {part_numbers: [2]}           -> 1 URL
  PUT  part 2                             -> tag e2
  POST complete {e1, e2, e3}              -> item processing
  saved record removed
  ```

- **Dead sessions**: an expired or non-resumable answer offers a fresh transfer. A saved record older than 24 h shows "expired" without calling the server.

## Proof

- New behaviour tests:
  - `savedTransfers.test`: per-account isolation, 24 h expiry flag, 7-day drop, matching on name, size and last-modified time.
  - `transfer.resume.test`: replay with the saved id, send only the missing part, complete with every tag.
  - `card.test`: the card offers Resume only for a pending item with a saved record, and refuses the wrong file.
- Before and after, in the card for item 901 (`sample.bin`, 3 parts, parts 1 and 3 sent):

  ```text
  BEFORE                                AFTER
  Transfer not finished                 Transfer not finished
  [Dismiss]                             [Resume transfer]  [Dismiss]
  -> start again from the first byte    -> re-pick sample.bin, send part 2 only
  ```

- Not checked here: an end-to-end resume against the staging service (real restart mid-transfer).

🤖 Generated with [Claude Code](https://claude.com/claude-code)


<!-- no-mistakes-pr-appendix:v1 sha256=0000000000000000000000000000000000000000000000000000000000000000 -->
## Intent

Build resume after refresh. The page saves each transfer's id plus file name, size and last-modified time when it starts; after a refresh or crash the card offers "Resume transfer", the user re-picks the file, the page checks it matches, replays the start call with the saved id, asks the server which parts it holds, and sends only the missing parts. Expired or non-resumable sessions say so and offer a fresh transfer.

## Risk Assessment

⚠️ Medium: a resumed transfer never deletes or aborts its item on cancel, failure or dismiss, and the tests assert both. One two-tab case stays open by choice: a new transfer's Dismiss can still delete an item that another tab finished through resume.

## Testing

- ⏭️ **Test** - skipped

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0000000000000000000000000000000000000000","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"skipped"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>⏭️ **Test** - skipped</summary>

Step was skipped.
</details>

<!-- /no-mistakes-pr-appendix:v1 -->
