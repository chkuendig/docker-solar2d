# docker-solar2d

A Linux Docker image for Solar2D: HTML5 and Android builds, a headless
simulator, and an MCP server over stdio.

## No downstream-consumer references

None of the Solar2D projects — this repo, the `solar2d` fork and `solar2d-mcp`
— may name a downstream project that consumes them, and in particular not the
game repo this image was extracted from.

These are general-purpose Solar2D tooling. The image grew inside a game repo
before it was pulled out, but nothing in it was ever specific to that game;
naming a consumer implies a coupling that does not exist and ties tooling work
to a single caller.

The rule covers everything the project publishes, not just the source tree:

- source files, comments, `README.md`, `Dockerfile`, the build scripts
- commit messages and branch names
- pull request and issue titles, bodies and review comments
- the GitHub repository description and topics
- CI workflow names, job names and log output

When a downstream failure motivates a change, describe it generically — "a
downstream project's nightly Android build", "a project compiling against
android-36" — and keep the reproduction, the error text and the fix, which are
the parts that belong here. Link evidence inside this repo (a `publish.yml`
run) rather than another repo's Actions runs.
