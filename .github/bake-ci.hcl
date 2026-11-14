# CI-only bake overlay: docker buildx bake -f docker-compose.yml -f .github/bake-ci.hcl
# Adds a BuildKit cache in the GitHub Actions cache for every target the compose file
# defines, plus the all-toolchains variant, so a PR that changes nothing in a layer
# does not rebuild it. Image tags match compose's own naming (<project>-<service>) so
# scripts/smoke.sh's `docker compose up` uses the loaded images instead of rebuilding.
# Nothing here affects a local `docker compose build`.
group "ci" {
  targets = ["lyngvi", "lyngvi-proxy", "lyngvi-all"]
}

target "lyngvi" {
  tags       = ["lyngvi-lyngvi"]
  cache-from = ["type=gha,scope=lyngvi"]
  cache-to   = ["type=gha,scope=lyngvi,mode=max"]
}

target "lyngvi-proxy" {
  tags       = ["lyngvi-lyngvi-proxy"]
  cache-from = ["type=gha,scope=lyngvi-proxy"]
  cache-to   = ["type=gha,scope=lyngvi-proxy,mode=max"]
}

# Every gated toolchain on, so no gated layer can rot unnoticed. Seeds from the
# default variant's cache (shared base layers) and keeps its own.
target "lyngvi-all" {
  inherits   = ["lyngvi"]
  args       = { WITH_GO = "1", WITH_FORGEJO_MCP = "1", WITH_GITHUB_MCP = "1" }
  tags       = ["lyngvi-lyngvi:all"]
  cache-from = ["type=gha,scope=lyngvi-all", "type=gha,scope=lyngvi"]
  cache-to   = ["type=gha,scope=lyngvi-all,mode=max"]
}
