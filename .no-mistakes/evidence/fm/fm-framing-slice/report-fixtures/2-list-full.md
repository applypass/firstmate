# Report
## Framing
- **Five whys:** signups drop because email lands in spam because SPF missing because DNS moved because migration skipped it
- **Need:** yes, 40% of signups never verify
- Who and how many: 1,200 new users per week
- How often - every signup
- Manual vs automated ROI: manual DNS fix is 10 minutes, no automation needed
- Product change: unknown - check if magic-link login removes verification
- Non-code way: add SPF record by hand
- Metric owner: growth lead owns verify rate
## Findings
SPF missing.
