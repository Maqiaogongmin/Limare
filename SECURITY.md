# Security

Please report vulnerabilities or suspected credential exposure privately to
**mail@limare.app**. This address accepts incoming mail; replies from the role
address are currently unavailable. Do not rely on a response deadline.

Include the affected Limare version, a description, impact, and minimal
reproduction steps. Remove API keys, tokens, personal information, and private
workspace contents from attachments. Do not open a public issue containing
vulnerability details or secrets.

Limare 0.1.0 supports Apple Silicon on macOS 15.0+. Models, MCP servers,
websites, Hooks, shell commands, and desktop automation can process data or
change your system according to your configuration and permissions. The main
app is not protected by Apple App Sandbox. See the
[privacy policy](https://limare.app/privacy/) for transmission and deletion
boundaries.

Security fixes will be announced through GitHub Releases and this repository's
security materials. Limare's update check is user-triggered; it does not check
for fixes in the background. Until a signed and notarized release is published,
there is no supported public binary download.

If a released artifact is unsafe, downloads and the update feed can be
withdrawn. Preserve its version and hash for investigation; use a new version
and tag for fixes rather than replacing the source behind an existing tag.
