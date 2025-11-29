#!/bin/bash

# filepath: /Users/Justin.Neubert/projects/v1flows/runner-plugins/generate_workflows.sh
# Generates GitHub workflows for all plugins with support for regular and pre-release versions

set -euo pipefail

WORKFLOWS_DIR=".github/workflows"
GO_VERSION='1.24'

# Color output for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

mkdir -p "$WORKFLOWS_DIR"

# Detect if version is a pre-release (contains alpha, beta, rc, etc.)
is_prerelease() {
  local version="$1"
  if [[ "$version" =~ -(alpha|beta|rc|a|b) ]]; then
    return 0
  fi
  return 1
}

generate_check_workflow() {
  local type="$1"
  local plugin="$2"
  local output_file="$WORKFLOWS_DIR/check-image-build-${type}-${plugin}.yml"
  
  cat > "$output_file" <<'EOL'
name: Check $type Build - $plugin

on:
  pull_request:
    types: [opened, reopened, edited, synchronize]
    branches: [ "develop" ]
    paths:
      - "$type/$plugin/**"

jobs:
  build-plugin:
    name: Build Plugin
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '$GO_VERSION'

      - name: Build Plugin
        working-directory: $type/$plugin
        run: go build
EOL
  
  # Perform actual variable substitution
  sed -i '' "s|\$type|$type|g" "$output_file"
  sed -i '' "s|\$plugin|$plugin|g" "$output_file"
  sed -i '' "s|\$GO_VERSION|$GO_VERSION|g" "$output_file"
  
  echo -e "${GREEN}✓${NC} Generated $output_file"
}

generate_stable_release_workflow() {
  local type="$1"
  local plugin="$2"
  local output_file="$WORKFLOWS_DIR/release-${type}-${plugin}.yml"
  
  cat > "$output_file" <<'EOL'
name: Release $type - $plugin

on:
  workflow_dispatch:
  push:
    branches: [ "main" ]
    paths:
      - "$type/$plugin/.version"
      - "$type/$plugin/**/*.go"

jobs:
  build-and-release:
    name: Build and Release $plugin
    runs-on: ubuntu-latest
    permissions: write-all
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Read Plugin Version
        id: read_version
        working-directory: $type/$plugin
        run: |
          VERSION=$(cat .version)
          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Check if Tag or Release Exists
        id: check-tag-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG_EXISTS=$(git ls-remote --tags origin | grep "refs/tags/$plugin-v${{ steps.read_version.outputs.version }}" || true)
          RELEASE_EXISTS=$(gh release list --repo ${{ github.repository }} | grep "Release $plugin v${{ steps.read_version.outputs.version }}" || true)
          if [ -n "${TAG_EXISTS}" ] || [ -n "${RELEASE_EXISTS}" ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '$GO_VERSION'

      - name: Build Plugin
        if: steps.check-tag-release.outputs.skip == 'false'
        working-directory: $type/$plugin
        run: |
          # Build versioned binaries
          for os in darwin linux; do
            for arch in amd64 arm64 arm ppc64le s390x; do
              # Skip darwin/386 as it's unsupported
              if [ "$os" = "darwin" ] && [ "$arch" = "386" ]; then
                continue
              fi
              GOOS=${os} GOARCH=${arch} go build -o $plugin-v${{ steps.read_version.outputs.version }}-${os}-${arch}
            done
          done
          
          # Build latest binaries
          for os in darwin linux; do
            for arch in amd64 arm64 arm ppc64le s390x; do
              # Skip darwin/386 as it's unsupported
              if [ "$os" = "darwin" ] && [ "$arch" = "386" ]; then
                continue
              fi
              GOOS=${os} GOARCH=${arch} go build -o $plugin-latest-${os}-${arch}
            done
          done

      - name: Create Version Tag
        if: steps.check-tag-release.outputs.skip == 'false'
        id: tag_version
        uses: mathieudutour/github-tag-action@v6.2
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          custom_tag: $plugin-v${{ steps.read_version.outputs.version }}
          tag_prefix: ''
      
      - name: Update Latest Tag
        if: steps.check-tag-release.outputs.skip == 'false'
        run: |
          set -e
          # Delete local and remote -latest tag if it exists
          git tag -d $plugin-latest 2>/dev/null || true
          git push origin :refs/tags/$plugin-latest 2>/dev/null || true
          # Create new -latest tag at current commit
          git tag $plugin-latest
          git push origin $plugin-latest --force

      - name: Create Version Release
        if: steps.check-tag-release.outputs.skip == 'false'
        id: create_version_release
        uses: ncipollo/release-action@v1
        with:
          name: Release $plugin v${{ steps.read_version.outputs.version }}
          tag: ${{ steps.tag_version.outputs.new_tag }}
          artifacts: $type/$plugin/$plugin-v${{ steps.read_version.outputs.version }}-*
          skipIfReleaseExists: true
          generateReleaseNotes: true
          prerelease: false
          token: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Create Latest Release
        if: steps.check-tag-release.outputs.skip == 'false'
        id: create_latest_release
        uses: ncipollo/release-action@v1
        with:
          name: Release $plugin latest
          tag: $plugin-latest
          artifacts: $type/$plugin/$plugin-latest-*
          skipIfReleaseExists: false
          generateReleaseNotes: false
          token: ${{ secrets.GITHUB_TOKEN }}
EOL
  
  # Perform actual variable substitution
  sed -i '' "s|\$type|$type|g" "$output_file"
  sed -i '' "s|\$plugin|$plugin|g" "$output_file"
  sed -i '' "s|\$GO_VERSION|$GO_VERSION|g" "$output_file"
  
  echo -e "${GREEN}✓${NC} Generated $output_file"
}

generate_prerelease_workflow() {
  local type="$1"
  local plugin="$2"
  local output_file="$WORKFLOWS_DIR/prerelease-${type}-${plugin}.yml"
  
  cat > "$output_file" <<'EOL'
name: Pre-release $type - $plugin

on:
  workflow_dispatch:
  push:
    branches: [ "develop" ]
    paths:
      - "$type/$plugin/.version"
      - "$type/$plugin/**/*.go"

jobs:
  check-version:
    name: Check Pre-release Version
    runs-on: ubuntu-latest
    outputs:
      is_prerelease: ${{ steps.check.outputs.is_prerelease }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Check if Version is Pre-release
        id: check
        working-directory: $type/$plugin
        run: |
          VERSION=$(cat .version)
          if [[ "${VERSION}" =~ -(alpha|beta|rc|a|b) ]]; then
            echo "is_prerelease=true" >> $GITHUB_OUTPUT
          else
            echo "is_prerelease=false" >> $GITHUB_OUTPUT
          fi

  build-and-prerelease:
    name: Build and Pre-release $plugin
    needs: check-version
    if: github.event_name == 'workflow_dispatch' || needs.check-version.outputs.is_prerelease == 'true'
    runs-on: ubuntu-latest
    permissions: write-all
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Read Plugin Version
        id: read_version
        working-directory: $type/$plugin
        run: |
          VERSION=$(cat .version)
          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Check if Tag or Release Exists
        id: check-tag-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          TAG_EXISTS=$(git ls-remote --tags origin | grep "refs/tags/$plugin-v${{ steps.read_version.outputs.version }}" || true)
          RELEASE_EXISTS=$(gh release list --repo ${{ github.repository }} | grep "Release $plugin v${{ steps.read_version.outputs.version }}" || true)
          if [ -n "${TAG_EXISTS}" ] || [ -n "${RELEASE_EXISTS}" ]; then
            echo "skip=true" >> $GITHUB_OUTPUT
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '$GO_VERSION'

      - name: Build Plugin
        if: steps.check-tag-release.outputs.skip == 'false'
        working-directory: $type/$plugin
        run: |
          # Build for multiple platforms
          for os in darwin linux; do
            for arch in amd64 arm64 arm ppc64le s390x; do
              # Skip darwin/386 as it's unsupported
              if [ "$os" = "darwin" ] && [ "$arch" = "386" ]; then
                continue
              fi
              GOOS=${os} GOARCH=${arch} go build -o $plugin-v${{ steps.read_version.outputs.version }}-${os}-${arch}
            done
          done

      - name: Create Version Tag
        if: steps.check-tag-release.outputs.skip == 'false'
        id: tag_version
        uses: mathieudutour/github-tag-action@v6.2
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          custom_tag: $plugin-v${{ steps.read_version.outputs.version }}
          tag_prefix: ''

      - name: Create Pre-release
        if: steps.check-tag-release.outputs.skip == 'false'
        id: create_prerelease
        uses: ncipollo/release-action@v1
        with:
          name: Pre-release $plugin v${{ steps.read_version.outputs.version }}
          tag: ${{ steps.tag_version.outputs.new_tag }}
          artifacts: $type/$plugin/$plugin-v${{ steps.read_version.outputs.version }}-*
          skipIfReleaseExists: true
          generateReleaseNotes: true
          prerelease: true
          token: ${{ secrets.GITHUB_TOKEN }}
EOL
  
  # Perform actual variable substitution
  sed -i '' "s|\$type|$type|g" "$output_file"
  sed -i '' "s|\$plugin|$plugin|g" "$output_file"
  sed -i '' "s|\$GO_VERSION|$GO_VERSION|g" "$output_file"
  
  echo -e "${GREEN}✓${NC} Generated $output_file"
}

# Main loop
echo -e "${BLUE}Generating GitHub workflows...${NC}"
for type in action-plugins endpoint-plugins; do
  echo -e "\n${BLUE}Processing: $type${NC}"
  for plugin in $(find "$type" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort); do
    echo "  Processing plugin: $plugin"
    generate_check_workflow "$type" "$plugin"
    generate_stable_release_workflow "$type" "$plugin"
    generate_prerelease_workflow "$type" "$plugin"
  done
done

echo -e "\n${GREEN}✓ Successfully generated workflow files for all plugins in $WORKFLOWS_DIR${NC}"