## Release

Promote dev to main.

## Commits

- Write a subscription history row on every tier change, at any client status (sc-11423)
- no-mistakes(document): Correct history-trigger firing rule in client-status doc
- Merge pull request #858 from applypass/fm/subhist-trigger

<!-- fm-release-gate:start -->
## Release gate

| PR | Story | Decision it implements | Current? | Data or API change | Reader and writer audit | Status |
|---|---|---|---|---|---|---|
| [#858](https://github.com/applypass/apply_pass_backend/pull/858) | sc-11423 | plan-apply_pass_backend-858 | yes | yes (schema.sql) | yes | ok |
| [#860](https://github.com/applypass/apply_pass_backend/pull/860) | sc-11500 sc-11652 | plan-apply_pass_backend-860 | yes | no | n/a | ok |
| [#861](https://github.com/applypass/apply_pass_backend/pull/861) | sc-11500 sc-11631 | plan-apply_pass_backend-861 | yes | no | n/a | ok |
<!-- fm-release-gate:end -->
