# GitHub identity across multiple accounts

Assume the machine has **more than one authenticated GitHub account**. Never assume the active
account is the right one, and never stop the workflow to make the user pick one. Resolve the account
in this order, falling through only when the previous source is absent or cannot satisfy the required
capability:

1. the `github_login` configured for this repository in the project conventions file;
2. the last login that succeeded for this exact target;
3. capability probing across the remaining authenticated logins.

Probing is the fallback, not the design. Discovering an identity by trying every account the user
owns is slow, and it can hand public authorship of a comment to an account that merely qualified
first. When probing does choose the account, say which one and why in the disclosure before the first
write.

Create `scripts/gh_identity.sh` as a complete executable Bash script.

It must:

- support authenticated `github.com` accounts from the GitHub CLI;
- accept every login shape GitHub actually issues, including Enterprise Managed User logins
  containing underscores; never strip, normalize, or reject a character GitHub accepts in a login;
- distinguish an unreachable or erroring GitHub API from a missing or invalid credential, and
  report an outage as an outage rather than blaming the saved login;
- accept a target as an issue or PR URL, or `OWNER/REPOSITORY#NUMBER`, or `OWNER/REPOSITORY`;
- accept a required capability: `read`, `comment`, `write`, or `push`;
- try the project conventions file's `github_login` for that repository first, then the previously
  successful login for that target;
- then try every other authenticated login until one satisfies the required capability;
- never interrupt the workflow to ask the user which account to use;
- support an explicit per-invocation login override without changing the saved default;
- verify the public login produced by each per-invocation credential before probing or executing;
- report every attempted login, and the capability that failed, when none qualifies;
- save only the last successful login per target in a private user configuration file created with
  user-only directory and file permissions;
- reject symlinked, group-writable, or world-writable identity and state paths;
- execute only a `gh` command, except for the separately constrained `git-push` operation below.

Use **per-invocation credentials only**. When the GitHub CLI can emit a token for a specific login,
run each command with that token supplied through the environment for that command only. If the
installed CLI cannot provide per-login credentials, report the missing capability and remain
read-only; never switch the global active account, because an unrelated user or process may be using
it outside this skill's lock.

Never write a token to disk, into a remote URL that is stored, into logs, or into any GitHub message.

Support:

```text
gh_identity.sh list
gh_identity.sh get TARGET
gh_identity.sh set LOGIN
gh_identity.sh select [--need read|comment|write|push] TARGET
gh_identity.sh exec [--user LOGIN] [--need read|comment|write|push] TARGET -- gh ARGS...
gh_identity.sh git-push [--user LOGIN] TARGET --repo OWNER/REPOSITORY \
  --remote-url HTTPS_URL --source LOCAL_REF --dest refs/heads/BRANCH [--force-with-lease SHA]
```

## Capability probing

Probe with non-mutating metadata and never by posting, editing, deleting, pushing, or submitting a
review merely to test permission:

- `read` — the login can fetch the target's metadata.
- `comment` — the login can read the target, the repository and target are writable in principle,
  and available metadata does not report the viewer, repository, or target as blocked, locked,
  archived, or interaction-restricted.
- `write` — the login's repository permission allows the intended write, such as submitting a review
  or opening a pull request.
- `push` — the login's repository permission allows pushing to the head branch, or the login owns the
  head fork.

Metadata probes are advisory because GitHub may enforce rules only during the write. When capability
cannot be established non-mutatingly, report it as `unknown`; the calling skill may make the already
authorized real write once and handle refusal, but must not create a probe mutation.

## Saved-login behavior

- `select TARGET` saves the first login verified for that target and capability.
- A successful authorized write may update the saved login to the verified author.
- `set LOGIN` verifies that the login is authenticated and saves it only as the preferred first
  candidate. It makes no claim about access to any future target.
- Failed credential probes, reads, or writes never replace a saved login.

## Selection timing and disclosure

Select an identity after syntactically parsing the target and before the first GitHub metadata read.
Pass the verified login through the helper for every later GitHub command.

Before the first GitHub write, disclose the selected public login and confirm that the user's
authorization applies to that login. If the readable login cannot perform the write, continue through
the remaining accounts and disclose any automatic credential change. If no account qualifies, remain
read-only and report the limitation.

## Git identity for pushes

Pushing is a GitHub write. Resolve a `push`-capable login before the first push, and push using that
identity's credentials for that command only. Do not rewrite the user's stored remotes, global Git
configuration, or credential helper state.

Implement `git-push` as a narrow wrapper around one `git push`. Validate the exact target repository,
canonical `https://github.com/OWNER/REPOSITORY.git` URL, source ref, destination head ref, and optional
expected remote SHA before execution. Refuse userinfo, alternate hosts or schemes, redirects, and
effective `url.*.insteadOf` rewrites. Supply the token through a per-command environment and a
private temporary `GIT_ASKPASS` helper that reads the token from the environment rather than
containing it; never place it in a command argument, stored URL, Git configuration, process log, or
returned output. Disable credential helpers and global/system Git configuration for the command,
skip untrusted pre-push hooks with `--no-verify`, set `GIT_TERMINAL_PROMPT=0`, delete the helper on
every exit path, and refuse deletion, tags, multiple destinations, and pushes outside
`refs/heads/`. A lease mismatch fails closed. When the runtime running the skill refuses the lease
flag itself, degrade explicitly: fetch and compare the exact expected remote SHA immediately before
a plain push, disclose the weaker guarantee, and never force-push with neither protection.
