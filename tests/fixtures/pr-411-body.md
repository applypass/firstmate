## Problem

- A Platinum user uploading a large interview recording (up to 5 GB) lost the whole upload if the page refreshed, the tab closed or the browser crashed. The "Upload not finished" card could only be dismissed, so they had to start again from byte zero.
- The backend half (apply_pass_backend PR 758) already keeps the session for 24 h and added `GET /api/recordings/{id}/uploadedParts`, but the frontend never used it.
- Ticket: sc-7824 (frontend half of sc-7088).

## Fix

- **Save on start** (`src/lib/api/recordings/savedUploads.ts`): when an upload starts, the page writes the `client_upload_id`, file name, size and last-modified, match/stage ids and (once known) the recording id to localStorage, keyed per account (`recording-uploads:v1:<client_id>`). It holds no file bytes and no ETags. The record goes away on success, cancel or failure, and is kept 7 days at most.
- **Resume flow** (`uploadRecording.ts`, `recordingUploadController.ts`): the "Upload not finished" card offers **Resume upload** (Platinum only). The user re-picks the file through the new `RecordingFilePicker`; the page refuses a file whose name, size or last-modified differs ("That is not the file you started uploading. Pick X (size), the same file, unchanged."). Then it replays `uploadStart` with the saved id, lists held parts with `uploadedParts`, asks `uploadParts` for URLs for the missing part numbers only, and completes with every ETag.
- Worked example: a 3-part upload of `interview.mp4` dies after parts 1 and 3 land.

  ```text
  refresh -> card for recording 901: "Upload not finished" [Resume upload]
  user re-picks interview.mp4 -> name/size/lastModified match saved record
  POST uploadStart {client_upload_id: saved}  -> 200 idempotent, same upload_id
  GET  recordings/901/uploadedParts           -> parts [1, 3]
  POST uploadParts {part_numbers: [2]}        -> 1 URL
  PUT  part 2                                 -> ETag e2
  POST uploadComplete {e1, e2, e3}            -> recording processing
  saved record removed
  ```

- **Dead sessions**: a 410 `upload_session_expired`, or a 409 `upload_not_resumable` / `recording_not_pending`, says the upload cannot resume and offers a fresh upload. A saved record older than 24 h shows "expired" without calling the server.
- **Fresh upload goes through the normal modal**, pre-filled with the picked file and the old stage, so consent and file checks always run.
- **A resume never deletes or aborts the recording**, whether it fails, is cancelled or is dismissed. Another tab may already have completed it, and the backend reaps an unfinished session after 24 h. A fresh upload or a dismissed dead card also leaves the old recording alone.
- Why localStorage plus a re-pick: a `File` handle cannot be stored, and the File System Access API is not in every browser. ETags are not stored because they go stale; the server's part listing is the source of truth. ADR-0014 records both rejected alternatives.
- Contract: refreshed `swagger.yml` from backend `dev` (adds `uploadedParts`), regenerated `src/types/api*.generated.ts` so the BFF allowlist forwards the new route, and added an MSW mock handler for it.
- Docs: `docs/business-logic.md` (new "Resume after refresh" rule) and ADR-0014 consequences updated.

## Proof

- New and extended behaviour tests:
  - `savedUploads.test.ts`: per-account isolation, 24 h expiry flag, 7-day drop, name+size+last-modified matching, storage that throws.
  - `uploadRecording.resume.test.ts`: replay with the saved id, upload only the missing part, complete with every ETag. Also covers no `uploadParts` call when every part is held, a fresh upload never listing parts, and an expired session or replay reported without abort.
  - `recordingUploadController.test.ts`: the record is saved, named, forgotten on complete or cancel, and kept on page unload. A resume sends only the missing part; 410 and 409 offer a fresh upload. No abort or delete happens on a failed or cancelled resume, or on a recording another tab completed.
  - `useMatchRecordingWrites.test.tsx`, `DocumentsTab.recordings.test.tsx`, `RecordingFilePicker.test.tsx` (incl. axe): card offers Resume only for a pending recording with a saved record on a Platinum account. They also cover the wrong-file refusal, the expired card, a fresh upload only after consent, and that the old recording stays when that fresh upload is cancelled.
- New Storybook story `DocumentsTab.resume.stories.tsx` for the resume card states.
- Before and after, in the card for recording 901 (`interview.mp4`, 3 parts, parts 1 and 3 uploaded):

  ```text
  BEFORE (dev)                          AFTER (this PR)
  Upload not finished                   Upload not finished
  [Dismiss]                             [Resume upload]  [Dismiss]
  -> start again from byte zero         -> re-pick interview.mp4, send part 2 only
  wrong file: n/a                       wrong file: "That is not the file you started
                                        uploading. Pick interview.mp4 (1.2 GB), the
                                        same file, unchanged."
  saved record 25 h old: n/a            expired: says so, offers [Start a fresh upload]
  ```

- Screenshots (from Storybook `DocumentsTab.resume.stories.tsx`, 8 captures: uploading 40%, before-refresh card, after-refresh resume offer, resuming, done, expired, wrong file wide and narrow) are on the author's machine and are not attached here yet; GitHub has no API to upload PR images.
- Not checked here: an end-to-end resume against api-test on test-app (real refresh mid-upload to DigitalOcean Spaces).

🤖 Generated with [Claude Code](https://claude.com/claude-code)


<!-- no-mistakes-pr-appendix:v1 sha256=c0076482af7597778469fd2acf6f4706d585e75f3bf38b601ef26316534766dd -->
## Intent

Captain decision ir-upload-resume-after-refresh (sc-7088): YES, build resume after refresh. Shape: the page saves each upload's client_upload_id plus file name, size and last-modified (localStorage, per user) when it starts; after a refresh or crash the 'Upload not finished' card offers 'Resume upload', the user re-picks the file, the page checks name+size+last-modified match (refuse with a clear message if not), calls uploadStart with the saved client_upload_id (server returns the same session), asks the server which parts Spaces already has, and uploads only the missing parts. Expired (24 h) or non-resumable sessions say so and offer a fresh upload. This item is the frontend half (sc-7824); the backend half is merged in apply_pass_backend PR 758. Behaviour tests.

Context: the backend half (PR 758, now on dev) added owner-only, Platinum-gated GET /api/recordings/:recording_id/uploadedParts returning { part_count, parts: [{ part_number, etag, size }] }. Errors: 404 not owner, 409 recording_not_pending (aborted or completed), 410 upload_session_expired, 409 upload_not_resumable if storage lost the upload. uploadStart replayed with the same client_upload_id returns 200 with idempotent: true and the same upload_id and recording; uploadParts presigns any part numbers; uploadComplete takes all ETags. Worked example: a 3-part upload with parts 1 and 3 done resumes by replaying uploadStart, listing parts [1,3], uploading only part 2, then completing with all three ETags.

## Risk Assessment

⚠️ Medium: The round-5 fix is correct and narrow: `uploadRecording.ts:412` now skips `uploadAbort` whenever `resume` is true, while a new upload still aborts on cancel or failure (test at line 173 still expects one abort). With rounds 4 and 5, a resumed upload never deletes or aborts its recording on cancel, failure or dismiss, and the tests assert both `seen.abort === 0` and `seen.deleted === []`. Risk stays medium because a known two-tab case remains open by the user's choice: a new upload's Dismiss can still delete a recording that another tab finished through resume. Cross-tab Resume hiding is a separate follow-up story.

## Testing

- ⏭️ **Test** - skipped

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"970b856d1f8e97adf40dd791122d08b1897e8ec6","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"review","status":"completed"},{"step":"test","status":"skipped"},{"step":"document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}]} -->

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>🔧 **Rebase** - 1 issue found → auto-fixed ✅</summary>

- ⚠️ `docs/business-logic.md` - merge conflict rebasing onto origin/dev

🔧 Fix applied.
✅ Re-checked - no issues remain.
</details>

<details>
<summary>🔧 **Review** - 2 issues found → auto-fixed (5) ✅</summary>

- ⚠️ `src/lib/api/recordings/savedUploads.ts:43` - The intent requires: &#39;Expired (24 h) or non-resumable sessions say so and offer a fresh upload.&#39; But readAll silently drops any saved record older than 24 h (savedAt &gt;= cutoff). savedAt is stamped before uploadStart, so the local record always expires slightly before the server session does. Example: a user refreshes mid-upload and comes back 25 h later. The &#39;Upload not finished&#39; card then shows no Resume button, no expired message and no fresh-upload offer, because resumable() returns null. The 410 upload_session_expired path, with its message and &#39;Start a fresh upload&#39; control, only runs for the rare replay that lands just inside the window. The user decides the remedy: keep expired records (or add a grace period) so the click reaches the server and shows the expired message, or show a local &#39;expired, start a fresh upload&#39; notice on the card.
- ⚠️ `app/components/kanban-board/useMatchRecordingWrites.ts:108` - startFresh dismisses the failed upload, which soft-deletes its recording through discardRecording, even when the failure code was recording_not_pending. That code is in RESUME_UNAVAILABLE_CODES (uploadRecording.ts:53) and also means the recording is already completed. Two-tab sequence on one account: tab A is uploading, so its saved record is in the shared localStorage. Tab B lists the recording as pending_upload and offers &#39;Resume upload&#39;. The user resumes in B, B replays the same session and uploads parts alongside A. A completes first. B&#39;s uploadComplete gets 409 recording_not_pending, so B shows freshUploadOffer. Clicking &#39;Start a fresh upload&#39; in B then deletes A&#39;s finished recording. Smallest fix: do not discard the recording (or do not offer a fresh upload) when the code is recording_not_pending and the recording may be complete. Alternatively, do not offer Resume while another tab may still own the session.

🔧 Fix applied.
2 warnings still open:

- ⚠️ `app/components/kanban-board/useMatchRecordingWrites.ts:108` - startFresh dismisses the failed upload, which soft-deletes its recording through discardRecording, even when the failure code was recording_not_pending. That code is in RESUME_UNAVAILABLE_CODES (uploadRecording.ts:53) and also means the recording is already completed. Two-tab sequence on one account: tab A is uploading, so its saved record is in the shared localStorage. Tab B lists the recording as pending_upload and offers &#39;Resume upload&#39;. The user resumes in B, B replays the same session and uploads parts alongside A. A completes first. B&#39;s uploadComplete gets 409 recording_not_pending, so B shows freshUploadOffer. Clicking &#39;Start a fresh upload&#39; in B then deletes A&#39;s finished recording. Smallest fix: do not discard the recording (or do not offer a fresh upload) when the code is recording_not_pending and the recording may be complete. Alternatively, do not offer Resume while another tab may still own the session.
- ⚠️ `app/components/kanban-board/useMatchRecordingWrites.ts:101` - An expired card&#39;s &#39;Start a fresh upload&#39; now uploads any file the user picks as a new recording. That skips the upload modal&#39;s checks: the consent checkbox (RECORDING_CONSENT_TEXT, docs/business-logic.md &#39;Consent&#39;) and validateUploadFile with its duration read. Example: a record saved 25 h ago for recording 812. The user clicks &#39;Start a fresh upload&#39; and picks another-take.mp4, which is what useMatchRecordingWrites.test.tsx exercises. resume() deletes 812 and calls startRecordingUpload with the new file, and no consent was ever given for that file. The round-2 fix added this expired branch, and it repeats the startFresh path at useMatchRecordingWrites.ts:124, which the first commit added and which also calls upload() without consent. RecordingFilePicker only limits the file types. You decide: should a fresh upload from a card ask for consent and run the modal&#39;s validation (for example by opening the upload modal with the stage preselected), or is the consent given for the first upload enough? This is a product and consent-policy call, not a mechanical fix.

🔧 Fix applied.
1 warning still open:

- ⚠️ `src/lib/api/recordings/recordingUploadController.ts:137` - Round 2 fixed only part of review-2, and the same data-loss path is still open. The fix keeps a recording only when the code is `recording_not_pending`. But a replayed `uploadStart` for a finished session answers `409 upload_not_resumable`, and swagger.yml:9907 and :9991 say that code covers &#39;aborted, failed, completed or expired&#39;. Example with two tabs: tab A uploads recording 812 and finishes it. Tab B still shows 812 as &#39;Upload not finished&#39; (pending_upload), and the user clicks Resume upload and picks the same file. In uploadRecording.ts:121, `startUpload` throws `upload_not_resumable` from `resumeFailureFrom`. The controller keeps `recordingId: 812`, which line 100 seeded from `resumeFrom`, and sets `freshUploadOffer`. The user then either clicks Dismiss (useMatchRecordingWrites.ts:138), or clicks &#39;Start a fresh upload&#39; and passes the modal (DocumentsTab onUpload → `discardStale({uploadId})` → useMatchRecordingWrites.ts:117). Both call `dismissRecordingUpload`, which soft-deletes 812, the recording tab A just finished. Fix: when the failure comes from the replayed `uploadStart` with `upload_not_resumable`, clear `recordingId` the same way `recording_not_pending` already does, so dismissing never deletes it. A `upload_not_resumable` from `uploadedParts` (storage lost the upload) can keep deleting, because there the recording is known to be pending. One more effect of the same code: an expired session replayed through `uploadStart` also comes back as `upload_not_resumable`, so the user sees the generic &#39;can no longer be resumed&#39; message instead of the 24 h expired message.

🔧 Fix applied.
2 warnings still open:

- ⚠️ `src/lib/api/recordings/recordingUploadController.ts:137` - Round 2 fixed only part of review-2, and the same data-loss path is still open. The fix keeps a recording only when the code is `recording_not_pending`. But a replayed `uploadStart` for a finished session answers `409 upload_not_resumable`, and swagger.yml:9907 and :9991 say that code covers &#39;aborted, failed, completed or expired&#39;. Example with two tabs: tab A uploads recording 812 and finishes it. Tab B still shows 812 as &#39;Upload not finished&#39; (pending_upload), and the user clicks Resume upload and picks the same file. In uploadRecording.ts:121, `startUpload` throws `upload_not_resumable` from `resumeFailureFrom`. The controller keeps `recordingId: 812`, which line 100 seeded from `resumeFrom`, and sets `freshUploadOffer`. The user then either clicks Dismiss (useMatchRecordingWrites.ts:138), or clicks &#39;Start a fresh upload&#39; and passes the modal (DocumentsTab onUpload → `discardStale({uploadId})` → useMatchRecordingWrites.ts:117). Both call `dismissRecordingUpload`, which soft-deletes 812, the recording tab A just finished. Fix: when the failure comes from the replayed `uploadStart` with `upload_not_resumable`, clear `recordingId` the same way `recording_not_pending` already does, so dismissing never deletes it. A `upload_not_resumable` from `uploadedParts` (storage lost the upload) can keep deleting, because there the recording is known to be pending. One more effect of the same code: an expired session replayed through `uploadStart` also comes back as `upload_not_resumable`, so the user sees the generic &#39;can no longer be resumed&#39; message instead of the 24 h expired message.
- ⚠️ `src/lib/api/recordings/recordingUploadController.ts:135` - Round 3 closed the &#39;Start a fresh upload&#39; path, but its sibling paths can still soft-delete a recording that another tab finished. Here is the two-tab sequence on one account. Tab A uploads recording 812, and its saved record (with recordingId 812) sits in the shared localStorage. Tab B&#39;s store does not hold 812, so B lists 812 as pending_upload, `resumable()` finds the saved record, and B shows &#39;Resume upload&#39;. The user resumes in B: B replays uploadStart, which is idempotent, and B gets presigned URLs for the missing parts. Tab A then completes 812. B&#39;s part PUTs now fail with 404 NoSuchUpload. `toPartFailure` turns that into `part_upload_failed`, which is not in RESUME_UNAVAILABLE_CODES, so line 135 keeps `recordingId: 812` (seeded from `resumeFrom` at line 100) on the failed card. Clicking Dismiss calls `dismissRecordingUpload` (line 154), and that DELETEs the completed recording 812. The same thing happens if the user clicks Cancel on B&#39;s resume card while A finishes: the RecordingUploadCancelledError branch (lines 127-130) calls `discardRecording(812)`. Round 2 and round 3 fixed this class only for the `recording_not_pending` / `upload_not_resumable` codes and for fresh uploads, so these sites remain: recordingUploadController.ts:127-130 (cancel of a resumed upload), recordingUploadController.ts:135 plus :151-156 (dismiss after a non-resume-code failure of a resumed upload). The root cause is useMatchRecordingWrites.ts:73 offering Resume for a saved record another tab may still own. The smallest remedy matches the captain&#39;s round-3 rule (&#39;unfinished old uploads are left for the 24 h reaper&#39;): never soft-delete the recording when the upload was a resume (`resumeFrom` set), on both cancel and dismiss. Because this changes what Cancel and Dismiss do for a resumed upload (the pending row stays until the reaper runs), the remedy needs your sign-off.

🔧 Fix applied.
1 warning still open:

- ⚠️ `src/lib/api/recordings/uploadRecording.ts:412` - Round 4 removed the soft-delete from a resumed upload&#39;s cancel, failure and dismiss. Two paths with the same root cause are still open. (1) A resumed upload still calls `uploadAbort` when it fails or the user cancels it (uploadRecording.ts:411-413). (2) Resume is offered in a second tab while the first tab is still uploading (useMatchRecordingWrites.ts:76-90, DocumentsTab.tsx:243). DocumentsTab.tsx:113-119 hides the pending row only for uploads in this tab&#39;s own store, and the saved record in localStorage is shared by every tab. Concrete sequence: tab A starts recording 812 (fresh upload, not yet finished), and its saved record carries recordingId 812. Tab B opens the panel, sees 812 as pending_upload, and `resumable(812)` finds A&#39;s record, so B shows &#39;Resume upload&#39;. The user re-picks the file in B. B replays uploadStart and gets the same session, then starts sending the missing parts. Path (a): the user cancels B, or one of B&#39;s PUTs fails. B&#39;s catch block calls `uploadAbort(812)`. The recording is still pending, so the backend aborts the multipart upload and marks 812 failed (swagger.yml:10255). Tab A&#39;s live upload then fails and its bytes are lost. That breaks the round-4 rule: &#39;Unfinished uploads are left to the 24 h reaper.&#39; Path (b): B finishes first and completes 812. A&#39;s uploadComplete then gets 409, and A&#39;s card fails holding recordingId 812, because A was a fresh upload and keeps the id (recordingUploadController.ts:135). When the user clicks Dismiss on A, `dismissRecordingUpload` (recordingUploadController.ts:157-160) DELETEs 812, which B just finished. That breaks the round-4 rule &#39;Do not delete a recording that completed&#39;, on a path the resume feature opened. Sites: uploadRecording.ts:411-413 (abort after a resume fails or is cancelled), recordingUploadController.ts:135 and :157-160 (a fresh upload&#39;s dismiss deletes a recording another tab completed through resume), useMatchRecordingWrites.ts:76-90 (Resume offered while another tab owns the upload). Remedy options, and both change behaviour, so you decide: skip `uploadAbort` when `resume` is true and leave the recording to the reaper (narrow; fixes path a only), and/or stop offering Resume while another tab owns the upload, which needs a new cross-tab lock or heartbeat in the saved record (new durable state). That remedy goes beyond the current change, so it needs your sign-off.

🔧 Fix applied.
✅ Re-checked - no issues remain.
</details>

<details>
<summary>⏭️ **Test** - skipped</summary>

Step was skipped.
</details>

<details>
<summary>✅ **Document** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Lint** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.
</details>

<!-- /no-mistakes-pr-appendix:v1 -->

