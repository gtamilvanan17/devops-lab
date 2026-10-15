# Security Policy

## This is a local lab
DevOps Lab is designed for a single developer machine:

- Every port is bound to `127.0.0.1` only.
- The default passwords (`admin123`) are public. **Do not reuse them and do not expose the lab to a network.**
- The Jenkins container runs as root and mounts the Docker socket so pipelines can build images. Anyone who can run a Jenkins job can control your Docker daemon.
- `jenkins_wp/` contains a kubeconfig with cluster admin access. It is git-ignored, so keep it that way.

## Reporting a vulnerability
Please report issues privately to the maintainer (use GitHub's "Report a vulnerability" button on the repository's Security tab) instead of opening a public issue. Expect an acknowledgement within a few days.

## Supported versions
Only the latest release receives fixes.
