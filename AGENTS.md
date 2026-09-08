# Repository workflow

- Keep the repository root directly installable as a Codex skill: `SKILL.md`, `agents/`, `references/`, and `scripts/` belong at the root.
- Treat a version as usable only after `quick_validate.py`, script syntax checks, and the relevant local or Arm64 target checks pass.
- Record each usable version in one coherent commit, update `VERSION`, create the matching annotated SemVer tag, and push that commit and tag before starting the next version.
- Do not squash multiple usable versions into one commit or rewrite a version that has already been pushed.
- Keep unverified performance claims separate from correctness, compile support, and runtime HWCAP evidence.
