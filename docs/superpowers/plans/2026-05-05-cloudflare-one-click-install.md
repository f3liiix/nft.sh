# Cloudflare One-Click Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a minimal Cloudflare distribution path for `curl -fsSL https://nft.hide.ss | sudo bash` and keep timer execution pinned to `/usr/local/sbin/nft.sh`.

**Architecture:** Add a Cloudflare static-assets deployment folder with `install.sh`, `worker.js`, and `wrangler.toml`. Update `nft.sh` so local-file runs still copy the current file, while pipe/process-substitution runs download the canonical script URL before installing the systemd timer path.

**Tech Stack:** Bash, nft.sh existing shell tests, Cloudflare Workers Static Assets, Wrangler configuration.

---

### Task 1: Installer and Self-Install Tests

**Files:**
- Modify: `tests/test_nft_sh.sh`
- Create: `tests/test_cloudflare_install.sh`

- [ ] Add a failing test in `tests/test_nft_sh.sh` showing `install_current_script_to_script_path` downloads `NFT_FORWARD_SCRIPT_URL` when `BASH_SOURCE[0]` is not a regular readable file.
- [ ] Add a failing test in `tests/test_cloudflare_install.sh` showing `deploy/cloudflare/public/install.sh` downloads `/nft.sh`, validates syntax, verifies `sha256.txt`, installs to `NFT_FORWARD_SCRIPT_PATH`, and executes the installed script.
- [ ] Run `bash tests/test_nft_sh.sh` and `bash tests/test_cloudflare_install.sh`; expected result before implementation is failure because download fallback and installer files do not exist.

### Task 2: nft.sh Download Fallback

**Files:**
- Modify: `nft.sh`

- [ ] Add `SCRIPT_URL="${NFT_FORWARD_SCRIPT_URL:-https://nft.hide.ss/nft.sh}"`.
- [ ] Add helpers to detect regular local source vs non-file source and download the canonical script using `curl_with_timeout`.
- [ ] Keep existing local copy behavior for normal `sudo bash nft.sh`.
- [ ] Run `bash tests/test_nft_sh.sh`; expected result after implementation is pass for self-install behavior.

### Task 3: Cloudflare Distribution Files

**Files:**
- Create: `deploy/cloudflare/public/install.sh`
- Create: `deploy/cloudflare/public/version`
- Create: `deploy/cloudflare/public/sha256.txt`
- Create: `deploy/cloudflare/src/worker.js`
- Create: `deploy/cloudflare/wrangler.toml`

- [ ] Implement `install.sh` with strict Bash mode, configurable base URL, optional SHA256 verification, syntax check, backup, install, and handoff to installed `nft.sh`.
- [ ] Add minimal Worker entry that delegates to static assets and maps `/` to `/install.sh` through asset serving semantics.
- [ ] Add Wrangler config for `nft-hide-ss` with static assets directory `public`.
- [ ] Run `bash tests/test_cloudflare_install.sh`; expected result after implementation is pass.

### Task 4: Documentation and Verification

**Files:**
- Modify: `README.md`

- [ ] Add one-click install command and Cloudflare deployment section.
- [ ] Run `bash -n nft.sh`.
- [ ] Run `bash -n deploy/cloudflare/public/install.sh`.
- [ ] Run `bash tests/test_nft_sh.sh`.
- [ ] Run `bash tests/test_domain_nat.sh`.
- [ ] Run `bash tests/test_cloudflare_install.sh`.
