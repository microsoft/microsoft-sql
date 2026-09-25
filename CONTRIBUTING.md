# Contributing to Microsoft SQL agent skills

Thank you for your interest in improving the Microsoft SQL agent plugins.

## Before you contribute

- Search existing [issues](../../issues) and [pull requests](../../pulls) before starting work.
- Use the [skill feedback form](../../issues/new?template=skill_feedback.yml) for incorrect,
  missing, stale, or unsafe guidance.
- Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a
  public issue.
- Follow the [Microsoft Open Source Code of Conduct](CODE_OF_CONDUCT.md).

## Contributor License Agreement

All contributions are subject to Microsoft's Contributor License Agreement (CLA). Most
contributions require you to agree to a CLA declaring that you have the right to, and actually
do, grant Microsoft the rights to use your contribution. For details, visit
[https://cla.opensource.microsoft.com](https://cla.opensource.microsoft.com).

When you submit a pull request, the CLA bot determines whether you need to provide a CLA and
adds the appropriate status check or comment. Follow the instructions provided by the bot. You
only need to complete this process once across repositories that use the Microsoft CLA.

## What to change

Plugin packages in this repository are generated from canonical source definitions. Pull
requests that improve marketplace metadata, documentation, compatibility, validation, or
repository governance are welcome.

If a bundled skill needs to change, open an issue before editing its generated copy. This keeps
the public package synchronized with its canonical source and prevents the next publication from
overwriting the fix.

## Pull requests

1. Create a focused branch and keep changes limited to one concern.
2. Do not include credentials, customer data, internal Microsoft information, generated
   binaries, or Microsoft product icons.
3. Run `node scripts/validate-distribution.mjs`.
4. Verify affected installation instructions or plugin behavior.
5. Describe the change, its user impact, and how you validated it.

By participating in this project, you agree to follow its
[Code of Conduct](CODE_OF_CONDUCT.md).
