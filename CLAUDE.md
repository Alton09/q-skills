# claude-skill-core

Project-agnostic skills for Claude Code workflows.

## Skills

Base skills in this repo are designed to compose across projects:

- **implement-plan**: Plan selection, worktree setup, phased implementation
- **goal**: Goal tracking and checkpoint verification
- **quality-gates**: Test, lint, coverage verification with retry logic

Projects extend these by adding local project-specific skills under `.claude/skills/`.

## Adding to a Project

1. Clone or reference this repo
2. Import base skills into your project's `.claude/skills/`
3. Create project-specific skills that wrap or delegate to base skills
4. Override CLAUDE.md with project-specific guidance as needed
