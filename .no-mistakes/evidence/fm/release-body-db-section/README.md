# Live validation: release PR body keeps its Database section

Product driven: bin/fm-release-gate.sh refresh (the call fm-release.sh open/merge makes),
against real GitHub reads for applypass/apply_pass_backend release PR #859 (base main, head dev).
A gh shim passed every read to the real gh and captured `gh pr edit --body-file` instead
of writing, so no PR on GitHub changed. The shim pinned compare/main...dev to #859's own range
(23bf34fd...caca6a57) so the schema.sql change from #858 is in scope.

The digest was checked with the real backend CI script, scripts/ci-checks/schema-applied.sh
from apply_pass_backend origin/dev (fix 1, PR 864), in a partial clone at #859's head.

Files:
- A-input-body-no-database.md   release body as the release tool opens it (no Database section)
- A-output-body.md              body after refresh: unticked Database line with digest dfcb1a7e6084
- A-refresh-transcript.txt      refresh exit 0
- A-digest-vs-real-schema-applied.txt  CI --digest = dfcb1a7e6084; unticked fails, ticked passes
- BCD-refresh-keeps-section.txt re-refresh no duplicate; ticked line survives refresh and CI passes;
                                real #859 body untouched; bare pasted tick adds no section
- B2-output-body-ticked-after-refresh.md  ticked body after a refresh rebuilt the gate table
- E-no-schema-change.txt        current real main...dev (no schema.sql): no section
- F-paginated-compare.txt       real multi-page compares: files only on page 1; GitHub-omitted
                                schema.sql patch warns and adds nothing; 94 KB patch digest matches CI
