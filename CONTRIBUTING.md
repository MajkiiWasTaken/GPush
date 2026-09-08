# Contributing to GPush

Thanks for your interest in contributing to GPush.

Contributions are welcome in the form of bug reports, feature suggestions, documentation improvements and pull requests.

## Reporting bugs

Before opening a new issue, please check whether the problem has already been reported.

When reporting a bug, include:

- GPush version
- operating system
- PowerShell or Bash version
- Git version
- steps to reproduce the problem
- expected behavior
- actual behavior
- relevant error output

## Suggesting features

Feature requests are welcome.

Please describe:

- what problem the feature would solve
- how you expect it to work
- whether it should work on Windows, Linux or both

## Pull requests

Before submitting a pull request:

1. Create a separate branch for your changes.
2. Keep changes focused on one feature or fix.
3. Make sure existing functionality still works.
4. Run available checks before submitting.
5. Update documentation if the behavior or commands change.

## Code quality

### Windows

PowerShell code should pass PSScriptAnalyzer without unnecessary warnings.

### Linux

Bash code should pass:

```bash
bash -n linux/gp
bash -n linux/install.sh
shellcheck linux/gp
shellcheck linux/install.sh
