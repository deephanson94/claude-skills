# claude-skills

Personal library of Claude Code skills. Kept separate from [dotfiles](https://github.com/deephanson94/dotfiles) on purpose: skills grow and get committed to constantly (closer to a codebase than machine config), and individual skills are meant to be reusable on their own — clonable into any project's `.claude/skills/` without dragging along tmux/Ghostty config.

This repo lives at `~/repos/claude-skills` and is symlinked to `~/.claude/skills` so Claude Code picks it up automatically. `dotfiles/install.sh` sets that up on a fresh machine (clones this repo if missing, `git pull`s it if already present, and creates the symlink).

## Layout

Each top-level directory is a skill, mirroring how Claude Code discovers them:

```
claude-skills/
├── <skill-name>/
│   └── SKILL.md
│   └── scripts/        (optional, if the skill ships helper scripts)
└── README.md
```

## Using a skill elsewhere

Clone the whole repo, or just copy the one skill folder you want into another project's `.claude/skills/<skill-name>/` — each skill is self-contained.
