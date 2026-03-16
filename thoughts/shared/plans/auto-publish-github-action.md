# Plan: Fix and Improve Auto-Publishing via GitHub Action

**Session**: `/Users/jtennant/.claude/projects/-Users-jtennant-Development/c15d1124-70ee-4610-966c-00e94fd82278/subagents/agent-ae179ce650cd10d08.jsonl`

## Current State

A GitHub Action already exists at `.github/workflows/release.yml` that:
- Triggers on push to `master`
- Auto-increments the patch version from the latest git tag
- Creates a git tag and GitHub release
- Attempts to update the Homebrew formula in `johnmatthewtennant/homebrew-tap`

**The workflow is failing.** Both runs (23123955373 and 23141018398) fail at the "Update Homebrew formula" step because the `TAP_TOKEN` secret is empty/not configured, causing a `git push` authentication failure.

The release creation step *does* succeed -- v0.5.1 and v0.5.2 releases exist on GitHub.

### Key facts
- Repo: `https://github.com/johnmatthewtennant/reminderkit-cli`
- Homebrew tap: `https://github.com/johnmatthewtennant/homebrew-tap`
- Formula: `Formula/reminderkit-cli.rb` (builds from source via `make`, depends_on `:macos`)
- Binary is macOS-only (uses private Apple frameworks)
- No code signing or notarization needed (private framework usage, distributed via source)
- The formula builds from source tarball (not a pre-built binary)
- Current latest tag: v0.5.2 (but no v0.5.2 tag locally -- created by CI)

## Tasks

### Task 1: Create a Personal Access Token (PAT) for tap repo access

**Manual step (cannot be automated by a coding agent).**

1. Go to https://github.com/settings/tokens
2. Create a **Fine-grained personal access token** with:
   - Repository access: `johnmatthewtennant/homebrew-tap` only
   - Permissions: Contents (read & write)
   - **Expiration**: 90 days (set a calendar reminder to rotate)
3. Go to https://github.com/johnmatthewtennant/reminderkit-cli/settings/secrets/actions
4. Add a repository secret named `TAP_TOKEN` with the PAT value

This is the root cause of the current failure. Once set, the existing workflow should work.

### Task 2: Fix the workflow to handle edge cases

Edit `.github/workflows/release.yml` with these improvements:

#### 2a. Add concurrency control

Prevent parallel runs from racing to create the same tag:

```yaml
concurrency:
  group: release
  cancel-in-progress: false
```

#### 2b. Add `workflow_dispatch` trigger with optional tag input

Allow manual re-runs targeting a specific tag (e.g., to retry a failed Homebrew update for an existing release):

```yaml
on:
  push:
    branches: [master]
  workflow_dispatch:
    inputs:
      tag:
        description: 'Existing tag to retry (e.g. v0.5.2). Leave empty for normal flow.'
        required: false
        type: string
```

#### 2c. Validate manual tag input

When `workflow_dispatch` provides a tag, validate it before proceeding:

```yaml
- name: Validate tag input (workflow_dispatch only)
  if: github.event.inputs.tag != ''
  run: |
    TAG="${{ github.event.inputs.tag }}"
    # Validate format
    if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "::error::Invalid tag format '$TAG'. Expected vX.Y.Z"
      exit 1
    fi
    # Validate tag exists
    if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
      echo "::error::Tag '$TAG' does not exist. Cannot retry a nonexistent release."
      exit 1
    fi
```

#### 2d. Detect existing tag (narrowed to release tags only)

Check whether HEAD already has a `v*` tag (not just any tag):

```yaml
- name: Check if already tagged
  id: check
  run: |
    EXISTING=$(git tag --points-at HEAD 'v*' | head -1)
    if [ -n "$EXISTING" ]; then
      echo "has_tag=true" >> $GITHUB_OUTPUT
      echo "tag=$EXISTING" >> $GITHUB_OUTPUT
    else
      echo "has_tag=false" >> $GITHUB_OUTPUT
    fi
```

#### 2e. Split tag and release creation into idempotent steps

Separate tag creation from release creation so each can be retried independently. Use `--verify-tag` on `gh release create` to prevent accidental tag creation:

```yaml
- name: Get next version
  if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
  id: version
  run: |
    LATEST=$(git tag -l 'v*' | sort -V | tail -1 | sed 's/v//')
    if [ -z "$LATEST" ]; then NEXT="0.1.0"; else
      MAJOR=$(echo $LATEST | cut -d. -f1)
      MINOR=$(echo $LATEST | cut -d. -f2)
      PATCH=$(echo $LATEST | cut -d. -f3)
      NEXT="$MAJOR.$MINOR.$((PATCH + 1))"
    fi
    echo "version=$NEXT" >> $GITHUB_OUTPUT
    echo "tag=v$NEXT" >> $GITHUB_OUTPUT

- name: Resolve tag
  id: resolve
  run: |
    # Priority: workflow_dispatch input > existing tag on HEAD > newly computed tag
    if [ -n "${{ github.event.inputs.tag }}" ]; then
      echo "tag=${{ github.event.inputs.tag }}" >> $GITHUB_OUTPUT
    elif [ "${{ steps.check.outputs.has_tag }}" = "true" ]; then
      echo "tag=${{ steps.check.outputs.tag }}" >> $GITHUB_OUTPUT
    else
      echo "tag=${{ steps.version.outputs.tag }}" >> $GITHUB_OUTPUT
    fi

- name: Create tag (if needed)
  if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
  run: |
    git tag ${{ steps.resolve.outputs.tag }}
    git push origin ${{ steps.resolve.outputs.tag }}

- name: Ensure release exists
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    TAG=${{ steps.resolve.outputs.tag }}
    if gh release view "$TAG" &>/dev/null; then
      echo "Release $TAG already exists."
    else
      echo "Creating release $TAG..."
      gh release create "$TAG" \
        --verify-tag \
        --title "$TAG" \
        --generate-notes
    fi
```

#### 2f. Fix the SHA computation -- fail if tarball never downloads

```yaml
- name: Update Homebrew formula
  env:
    TAP_TOKEN: ${{ secrets.TAP_TOKEN }}
  run: |
    if [ -z "$TAP_TOKEN" ]; then
      echo "::error::TAP_TOKEN secret is not set. Cannot update Homebrew formula."
      exit 1
    fi

    TAG=${{ steps.resolve.outputs.tag }}

    # Wait for tarball to be available
    TARBALL_OK=false
    for i in 1 2 3 4 5; do
      HTTP_CODE=$(curl -sL -o /tmp/release.tar.gz -w '%{http_code}' \
        "https://github.com/johnmatthewtennant/reminderkit-cli/archive/refs/tags/${TAG}.tar.gz")
      if [ "$HTTP_CODE" = "200" ]; then
        TARBALL_OK=true
        break
      fi
      echo "Tarball not ready (HTTP $HTTP_CODE), retrying in 5s..."
      sleep 5
    done

    if [ "$TARBALL_OK" != "true" ]; then
      echo "::error::Failed to download tarball after 5 attempts."
      exit 1
    fi

    SHA=$(shasum -a 256 /tmp/release.tar.gz | cut -d' ' -f1)

    # Clone tap using credential helper (avoid token in URL)
    git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=${TAP_TOKEN}"; }; f'
    git clone https://github.com/johnmatthewtennant/homebrew-tap.git /tmp/homebrew-tap
    cd /tmp/homebrew-tap

    # Tightly-anchored sed replacements (match only lines starting with expected whitespace + key)
    sed -i '' 's|^  url "https://github.com/johnmatthewtennant/reminderkit-cli/archive/.*"|  url "https://github.com/johnmatthewtennant/reminderkit-cli/archive/refs/tags/'"${TAG}"'.tar.gz"|' Formula/reminderkit-cli.rb
    sed -i '' 's|^  sha256 ".*"|  sha256 "'"${SHA}"'"|' Formula/reminderkit-cli.rb

    # Verify the formula references the correct tag before committing
    if ! grep -q "${TAG}" Formula/reminderkit-cli.rb; then
      echo "::error::Formula does not reference ${TAG} after sed. Aborting."
      exit 1
    fi

    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add Formula/reminderkit-cli.rb

    # Skip commit if formula is unchanged (idempotent)
    if git diff --cached --quiet; then
      echo "Formula already up to date. Nothing to push."
      exit 0
    fi

    git commit -m "reminderkit-cli: bump to ${TAG}"
    git push
```

### Task 3: Add skip-ci support

Allow commits with `[skip-release]` in the message to skip the release. The condition must also tolerate `workflow_dispatch` where `head_commit` is null:

```yaml
jobs:
  release:
    if: >-
      github.event_name == 'workflow_dispatch' ||
      !contains(github.event.head_commit.message, '[skip-release]')
```

### Task 4: (Optional) Add a pre-built binary to the release

This is optional and can be added later. If desired, add these steps (gated on new release only):

```yaml
- name: Build binary
  if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
  run: make

- name: Upload binary to release
  if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh release upload ${{ steps.resolve.outputs.tag }} reminderkit
```

The Homebrew formula will still build from source regardless. The binary is a convenience for direct download only.

## Complete Updated Workflow

Here is the full replacement for `.github/workflows/release.yml`:

```yaml
name: Auto Release & Homebrew Bump

on:
  push:
    branches: [master]
  workflow_dispatch:
    inputs:
      tag:
        description: 'Existing tag to retry (e.g. v0.5.2). Leave empty for normal flow.'
        required: false
        type: string

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release:
    runs-on: macos-latest
    if: >-
      github.event_name == 'workflow_dispatch' ||
      !contains(github.event.head_commit.message, '[skip-release]')
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Validate tag input (workflow_dispatch only)
        if: github.event.inputs.tag != ''
        run: |
          TAG="${{ github.event.inputs.tag }}"
          # Validate format
          if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            echo "::error::Invalid tag format '$TAG'. Expected vX.Y.Z"
            exit 1
          fi
          # Validate tag exists
          if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
            echo "::error::Tag '$TAG' does not exist. Cannot retry a nonexistent release."
            exit 1
          fi

      - name: Check if already tagged
        id: check
        run: |
          EXISTING=$(git tag --points-at HEAD 'v*' | head -1)
          if [ -n "$EXISTING" ]; then
            echo "has_tag=true" >> $GITHUB_OUTPUT
            echo "tag=$EXISTING" >> $GITHUB_OUTPUT
          else
            echo "has_tag=false" >> $GITHUB_OUTPUT
          fi

      - name: Get next version
        if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
        id: version
        run: |
          LATEST=$(git tag -l 'v*' | sort -V | tail -1 | sed 's/v//')
          if [ -z "$LATEST" ]; then
            NEXT="0.1.0"
          else
            MAJOR=$(echo $LATEST | cut -d. -f1)
            MINOR=$(echo $LATEST | cut -d. -f2)
            PATCH=$(echo $LATEST | cut -d. -f3)
            NEXT="$MAJOR.$MINOR.$((PATCH + 1))"
          fi
          echo "version=$NEXT" >> $GITHUB_OUTPUT
          echo "tag=v$NEXT" >> $GITHUB_OUTPUT

      - name: Resolve tag
        id: resolve
        run: |
          # Priority: workflow_dispatch input > existing tag on HEAD > newly computed tag
          if [ -n "${{ github.event.inputs.tag }}" ]; then
            echo "tag=${{ github.event.inputs.tag }}" >> $GITHUB_OUTPUT
          elif [ "${{ steps.check.outputs.has_tag }}" = "true" ]; then
            echo "tag=${{ steps.check.outputs.tag }}" >> $GITHUB_OUTPUT
          else
            echo "tag=${{ steps.version.outputs.tag }}" >> $GITHUB_OUTPUT
          fi

      - name: Create tag (if needed)
        if: steps.check.outputs.has_tag != 'true' && github.event.inputs.tag == ''
        run: |
          git tag ${{ steps.resolve.outputs.tag }}
          git push origin ${{ steps.resolve.outputs.tag }}

      - name: Ensure release exists
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG=${{ steps.resolve.outputs.tag }}
          if gh release view "$TAG" &>/dev/null; then
            echo "Release $TAG already exists."
          else
            echo "Creating release $TAG..."
            gh release create "$TAG" \
              --verify-tag \
              --title "$TAG" \
              --generate-notes
          fi

      - name: Update Homebrew formula
        env:
          TAP_TOKEN: ${{ secrets.TAP_TOKEN }}
        run: |
          if [ -z "$TAP_TOKEN" ]; then
            echo "::error::TAP_TOKEN secret is not set. Cannot update Homebrew formula."
            exit 1
          fi

          TAG=${{ steps.resolve.outputs.tag }}

          # Wait for tarball to be available
          TARBALL_OK=false
          for i in 1 2 3 4 5; do
            HTTP_CODE=$(curl -sL -o /tmp/release.tar.gz -w '%{http_code}' \
              "https://github.com/johnmatthewtennant/reminderkit-cli/archive/refs/tags/${TAG}.tar.gz")
            if [ "$HTTP_CODE" = "200" ]; then
              TARBALL_OK=true
              break
            fi
            echo "Tarball not ready (HTTP $HTTP_CODE), retrying in 5s..."
            sleep 5
          done

          if [ "$TARBALL_OK" != "true" ]; then
            echo "::error::Failed to download tarball after 5 attempts."
            exit 1
          fi

          SHA=$(shasum -a 256 /tmp/release.tar.gz | cut -d' ' -f1)

          # Clone tap using credential helper (avoid token in URL)
          git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=${TAP_TOKEN}"; }; f'
          git clone https://github.com/johnmatthewtennant/homebrew-tap.git /tmp/homebrew-tap
          cd /tmp/homebrew-tap

          # Tightly-anchored sed replacements
          sed -i '' 's|^  url "https://github.com/johnmatthewtennant/reminderkit-cli/archive/.*"|  url "https://github.com/johnmatthewtennant/reminderkit-cli/archive/refs/tags/'"${TAG}"'.tar.gz"|' Formula/reminderkit-cli.rb
          sed -i '' 's|^  sha256 ".*"|  sha256 "'"${SHA}"'"|' Formula/reminderkit-cli.rb

          # Verify the formula references the correct tag
          if ! grep -q "${TAG}" Formula/reminderkit-cli.rb; then
            echo "::error::Formula does not reference ${TAG} after sed. Aborting."
            exit 1
          fi

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Formula/reminderkit-cli.rb

          # Skip commit if formula is unchanged (idempotent)
          if git diff --cached --quiet; then
            echo "Formula already up to date. Nothing to push."
            exit 0
          fi

          git commit -m "reminderkit-cli: bump to ${TAG}"
          git push
```

## Implementation Checklist

1. [ ] **Manual**: Create PAT (90-day expiry) and add `TAP_TOKEN` secret to the reminderkit-cli repo (Task 1)
2. [ ] Replace `.github/workflows/release.yml` with the updated workflow above (Tasks 2-3)
3. [ ] Push to master and verify the workflow succeeds
4. [ ] Verify the Homebrew formula was updated in the tap repo
5. [ ] Verify `brew upgrade reminderkit-cli` picks up the new version
6. [ ] (Optional) Add binary upload steps from Task 4 if desired

## Notes

- **No signing/notarization needed**: The binary uses private Apple frameworks via `dlopen`/`objc_msgSend`, which means it won't pass notarization anyway. Users install via Homebrew which builds from source locally.
- **macOS runner required**: The `make` step needs `clang` with `-framework Foundation`, which is only available on macOS runners.
- **Architecture**: `macos-latest` on GitHub Actions uses Apple Silicon (M1+). The pre-built binary attached to the release will be arm64. The Homebrew formula builds from source so it matches the user's architecture automatically.
- **No version file**: Versions are tracked entirely via git tags. The workflow auto-increments patch. For minor/major bumps, manually create a tag before pushing.
- **Concurrency**: The `concurrency` group ensures only one release workflow runs at a time, preventing tag races.
- **Idempotent steps**: Tag creation, release creation, and Homebrew update are all idempotent -- safe to re-run without side effects.
- **Token security**: The credential helper approach avoids embedding the PAT in clone URLs, reducing risk of log exposure.
- **Manual retry**: Use `workflow_dispatch` with the `tag` input to retry a failed Homebrew update for a specific release without creating a new one.
