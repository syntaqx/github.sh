# `github.sh` - Keep your repositories in sync.

A simple helper script to clone and update all repositories of a GitHub
organization. This is useful for developers who want to work with multiple
repositories without having to clone each one individually, and for ensuring
that all repositories are up-to-date.

The way I use this script is because all of my repositories are cloned into the
base directory of `~/Code/<organization|username>`. This sits in the
`~/Code` directory, and I can easily update any organization or user's
repositories by running this script.

## Prerequisites

- `git` must be installed on your system.
- `jq` must be installed on your system for JSON parsing.
- `curl` must be installed on your system for making HTTP requests.
- You must be able to `git clone git@` repositories, which requires SSH access to GitHub.

## Usage

```bash
./github.sh <organization>
```
