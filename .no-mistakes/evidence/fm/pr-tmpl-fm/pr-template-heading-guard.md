# pr.template heading-guard analysis (no-mistakes v1.79.0 fc540ac, the daemon version on this host)

## Upstream guard source (internal/pipeline/steps/pr_template.go)
var prTemplateH1Line = regexp.MustCompile(`^ {0,3}#(?:[ \t]|$)`)
// This is a structural guard, not a Markdown/template interpreter. A drafting
// failure must not silently replace the team's H1 text/order. Subordinate
// completion is best effort, not an enforced policy. No H1s means no structural
// requirements. Existing published narrative never goes through this check again.
func validateTemplateStructure(template, body string) error {
	rest := templateStructureLines(body)
	for _, line := range templateStructureLines(template) {
		found := false
		for len(rest) > 0 {
			candidate := rest[0]
			rest = rest[1:]
			if candidate == line {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("agent changed, omitted or reordered a pr.template top-level # heading; refusing publication")
		}
	}
	return nil
}

## Upstream doc (repo-config.md, pr.template)
> Only top-level ATX `#` headings outside fenced examples are structurally required ... Lower-level headings (`##`-`######`) and task lines are editable: the model may remove inapplicable sections/options

## Heading lines in .github/pull_request_template.md at 0c4e38a
1:## Problem
5:## Fix
9:## Proof

## Required-heading set the guard extracts (same regex ^ {0,3}#(?:[ 	]|$), applied by python3 - mirror, not the Go binary)
[]

## Same check if the headings were H1 (# Problem / # Fix / # Proof)
['# Problem', '# Fix', '# Proof']

## Template byte checks
     377
utf8 ok, NUL: False ctrl(non-\n\t): False

## Parsed pr block (ruby YAML)
{"template"=>".github/pull_request_template.md"}
