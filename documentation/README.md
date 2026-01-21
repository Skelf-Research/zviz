# ZViz Documentation

This directory contains the user-facing documentation for ZViz, built with [MkDocs](https://www.mkdocs.org/) and the [Material theme](https://squidfunk.github.io/mkdocs-material/).

## Quick Start

### Prerequisites

- Python 3.8+
- pip

### Setup

```bash
# Install dependencies
pip install -r requirements.txt

# Start development server
mkdocs serve

# Open http://localhost:8000
```

### Build

```bash
# Build static site
mkdocs build

# Output is in site/
```

## Structure

```
documentation/
├── mkdocs.yml          # MkDocs configuration
├── requirements.txt    # Python dependencies
├── docs/
│   ├── index.md                    # Home page
│   ├── getting-started/            # Installation & quickstart
│   │   ├── index.md
│   │   ├── installation.md
│   │   ├── quickstart.md
│   │   └── first-container.md
│   ├── user-guide/                 # User documentation
│   │   ├── index.md
│   │   ├── profiles.md
│   │   ├── profile-authoring.md
│   │   ├── builtin-profiles.md
│   │   ├── cli-reference.md
│   │   └── troubleshooting.md
│   ├── operator-guide/             # Operator documentation
│   │   ├── index.md
│   │   ├── kubernetes.md
│   │   ├── containerd.md
│   │   ├── monitoring.md
│   │   ├── performance.md
│   │   ├── debugging.md
│   │   └── upgrades.md
│   ├── architecture/               # Technical architecture
│   │   ├── index.md
│   │   ├── enforcement-model.md
│   │   ├── broker-design.md
│   │   ├── threat-model.md
│   │   └── performance.md
│   ├── security/                   # Security documentation
│   │   ├── index.md
│   │   ├── reporting.md
│   │   ├── advisories.md
│   │   └── hardening.md
│   ├── reference/                  # Reference documentation
│   │   ├── profile-schema.md
│   │   ├── configuration.md
│   │   ├── metrics.md
│   │   └── error-codes.md
│   ├── contributing/               # Contributor documentation
│   │   ├── index.md
│   │   ├── development.md
│   │   ├── code-style.md
│   │   ├── testing.md
│   │   └── releases.md
│   └── assets/                     # Static assets (images, etc.)
└── site/                           # Built site (gitignored)
```

## Writing Documentation

### Style Guide

- Use clear, concise language
- Include code examples
- Add admonitions for warnings/tips
- Cross-link related pages

### Markdown Extensions

We use these Markdown extensions:

```markdown
# Admonitions
!!! note "Title"
    Content

!!! warning
    Warning content

# Code blocks with annotations
```python
code  # (1)!
```

1. Annotation text

# Tabs
=== "Tab 1"
    Content

=== "Tab 2"
    Content

# Mermaid diagrams
```mermaid
graph LR
    A --> B
```
```

### Testing Changes

```bash
# Live reload during development
mkdocs serve

# Build and check for errors
mkdocs build --strict
```

## Deployment

Documentation is automatically deployed on merge to main:

```yaml
# .github/workflows/docs.yml
name: docs
on:
  push:
    branches: [main]
    paths: ['documentation/**']
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v4
        with:
          python-version: '3.11'
      - run: pip install -r documentation/requirements.txt
      - run: mkdocs gh-deploy --force
        working-directory: documentation
```

## Related

- [Developer docs](../docs/) - Internal technical documentation
- [README](../README.md) - Project overview
