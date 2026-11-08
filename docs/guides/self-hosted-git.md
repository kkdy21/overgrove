# Self-hosted and corporate Git servers

> Status: Accepted · Related: #152, #161, #150, #153, #117 · 한국어: [self-hosted-git.ko.md](self-hosted-git.ko.md)

Overgrove reads any Git repository, whatever its host: Forgejo, Gitea, GitLab, Bitbucket, GitHub Enterprise, or a server in your company. Its only network operation is **Fetch**, and Fetch uses the authentication you have already set up for Git. Overgrove never asks for a password or token and never stores one.

Overgrove opens repositories it may not trust. So it runs Git in a hardened way, and a few setups that work in Terminal need one extra step. This guide covers those steps.

## How Overgrove runs Fetch

| What | What Overgrove does | What it means for you |
|---|---|---|
| Prompts | `GIT_TERMINAL_PROMPT=0` and empty `GIT_ASKPASS`/`SSH_ASKPASS` | Nothing can ask you for a password, passphrase, or host key. Credentials must already be stored |
| HTTPS credentials | Uses the credential helpers from your **system and global** Git configuration (including `~/.config/git/config`, files they include, and Apple Git's built-in settings), for example `osxkeychain` or Git Credential Manager. A repository's own `credential.helper` is ignored | Store the token once with Terminal (below) |
| SSH | Runs `ssh -o BatchMode=yes`, or your **system or global** `core.sshCommand` if you set one. A repository's own `core.sshCommand` is ignored. Your `~/.ssh/config` and the SSH agent (`SSH_AUTH_SOCK`) are used as usual | Keys must be in the agent or the macOS keychain, and the host must already be in `known_hosts` |
| Environment | Only a short allowlist reaches Git (`HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SSH_AUTH_SOCK`, plus fixed values). Your shell's other variables do not | `HTTPS_PROXY`, `GIT_SSH_COMMAND`, and similar shell variables have no effect. Put settings in your global Git config instead |
| Transports | Only Git's built-in transports: `https`, `http`, `ssh`, `git`, `file` | `ftp://`/`ftps://` remotes and custom remote helpers cannot be fetched (see [Limits](#limits)) |
| TLS | A repository cannot turn off certificate checks. If its own config sets a CA or client certificate, Fetch is turned off for that repository | Set CAs and client certificates in your global config |
| Time limit | A fetch is stopped after 120 seconds | Very large first fetches are better done once in Terminal, in a repository you trust |

Viewing worktrees, history, and diffs never uses the network, so none of this affects them.

> **Use Terminal only for repositories you trust.** Git in Terminal is not hardened: it runs the repository's hooks, its own `core.sshCommand`, credential helpers, proxies, and pager. Overgrove's fetch failure details offer Git commands only when the repository's configuration report is clean. Follow the steps below for repositories you trust.

## HTTPS with a token

Overgrove uses the token your credential helper has stored. Store it once:

1. Check that a helper is set. Run this outside any repository (for example in your home folder), so no repository's settings apply: `git --no-pager config --show-origin --get-all credential.helper`.
   - Apple's Git (Xcode or Command Line Tools) sets `osxkeychain` in its system config.
   - Git Credential Manager (`brew install --cask git-credential-manager`) adds itself to your global config.
2. Let Git ask for the token once, in Terminal, outside any repository: `git ls-remote https://git.example.com/team/app.git` (use your remote's URL). Enter your user name and the token (personal access token or app password) when Git asks. The helper saves it in the keychain. Running `git fetch` in a repository you trust works too.
3. Fetch in Overgrove.

If you use several accounts on one host, give each a URL-specific helper or user name in your **global** config, for example `git config --global credential.https://git.example.com.username alice`.

If the token expires, Fetch fails with "Authentication failed". Repeat step 2 to store a new one.

## SSH

1. **Add the host key once.** Overgrove cannot answer the "Are you sure you want to continue connecting?" question.
   - Connect once in Terminal (`ssh -T git@git.example.com`), check the fingerprint with your server admin, and accept it.
   - Or fetch the key, compare it **before** you trust it, then add it:

     ```sh
     ssh-keyscan -p 22 git.example.com > /tmp/host-key
     ssh-keygen -lf /tmp/host-key          # compare with the fingerprint your admin publishes
     cat /tmp/host-key >> ~/.ssh/known_hosts   # only if it matches
     ```
2. **Load your key without a passphrase prompt.** Run `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`. To load it automatically, add this to `~/.ssh/config`:

   ```
   Host git.example.com
     UseKeychain yes
     AddKeysToAgent yes
     IdentityFile ~/.ssh/id_ed25519
   ```

3. **Custom ports, jump hosts, and per-host keys** belong in `~/.ssh/config` (`Port`, `ProxyJump`, `IdentityFile`). Overgrove's ssh reads it.
4. **A custom SSH command** can go in your global config: `git config --global core.sshCommand "ssh -o BatchMode=yes -i ~/.ssh/work_key"`. Keep `-o BatchMode=yes` in it. Without it, ssh may wait for a prompt nobody can answer until the 120-second limit stops the fetch.

## A private certificate authority

If your server's certificate is signed by a company CA, point Git at the CA bundle in your **global** config:

```sh
git config --global http.sslCAInfo /path/to/company-ca.pem
# or only for that server:
git config --global http.https://git.example.com/.sslCAInfo /path/to/company-ca.pem
```

Client certificates work the same way (`http.sslCert`, `http.sslKey`, global or per URL).

If a **repository's own** config sets `http.sslCAInfo`, `http.sslCAPath`, `http.sslCert`, or `http.sslKey`, Overgrove turns off Fetch for that repository and says why. A repository could otherwise trust a certificate of its choosing for your credentials. Move the setting to your global config and remove it from the repository (`git config --local --unset http.sslCAInfo`). A repository also cannot set `http.sslVerify=false`: Overgrove fetches with verification on.

## Proxies

Overgrove does not pass your shell's `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY`, or `NO_PROXY` to Git, and Git does not read macOS network proxy settings. Set the proxy in your **global** Git config:

```sh
git config --global http.proxy http://proxy.example.com:8080
# or only for one server:
git config --global http.https://git.example.com/.proxy http://proxy.example.com:8080
```

A proxy set in a repository's own config is replaced by your global value (or by no proxy), so that a repository cannot send your credentials through a proxy of its choosing.

For SSH remotes, use `ProxyCommand` or `ProxyJump` in `~/.ssh/config`. A global `core.gitProxy` (for `git://` remotes) is not used.

Shell proxy variables will stay unused: an app opened from Finder never sees them, so passing them would make Fetch behave differently depending on how Overgrove was started ([ADR-0022](../adr/0022-no-shell-proxy-env-vars.md)). If you use `HTTPS_PROXY` in your shell, put the same value in `git config --global http.proxy` as shown above.

## Remote URL examples

Any form Git accepts works, as long as it uses a built-in transport.

| Server | HTTPS | SSH |
|---|---|---|
| Forgejo / Gitea | `https://git.example.com/team/app.git` | `ssh://git@git.example.com:2222/team/app.git` |
| GitLab (self-managed) | `https://gitlab.example.com/group/subgroup/app.git` | `git@gitlab.example.com:group/subgroup/app.git` |
| Bitbucket Data Center | `https://bitbucket.example.com/scm/proj/app.git` | `ssh://git@bitbucket.example.com:7999/proj/app.git` |
| GitHub Enterprise Server | `https://github.example.com/org/app.git` | `git@github.example.com:org/app.git` |

## When Fetch fails

Overgrove shows the reason in the status bar (`Fetch failed — Details`). The details name one of these:

| Overgrove says | Usual cause | What to do |
|---|---|---|
| Authentication failed for … | No stored credentials, or an expired token | [HTTPS with a token](#https-with-a-token) |
| The SSH key was rejected for … | The key is not in the agent, or the server does not know it | [SSH](#ssh), step 2. Check with `ssh-add -l` |
| The SSH host key of … is not trusted yet / has changed | The host is not in `known_hosts`, or its key changed | [SSH](#ssh), step 1. If the key **changed** unexpectedly, ask your admin before accepting it |
| Access to … was denied | The account cannot read the repository | Check your access, or set the right user name for that host |
| Could not reach … | Network, VPN, or proxy | [Proxies](#proxies). Check VPN |
| Fetch timed out after … s | Slow link or a very large repository | Fetch once in Terminal, in a repository you trust |
| The repository for … was not found | Wrong URL, or a private repository you cannot see | Check the URL with `git --no-pager remote -v`, in a repository you trust |
| Overgrove does not fetch … | `ftp://`, `ftps://`, or a custom remote helper | See [Limits](#limits) |
| Fetching … is turned off for this repository | The repository's own config sets a CA, client certificate, or similar; or a partial clone with Git older than 2.45.1 | [A private certificate authority](#a-private-certificate-authority), [Limits](#limits) |

## Limits

- **Built-in transports only.** Remotes that need a custom remote helper (`codecommit::…`, `gcrypt::…`, `hg::…`, or a URL that a repository rewrites to one) cannot be fetched in v0.1. A repository could otherwise pick a helper program and its arguments. If this is ever allowed, it will be an app setting you choose, not something a repository can turn on.
- **`ftp://` and `ftps://`** are built into Git but rarely used, so they are not on the allowed list.
- **`git://` through `core.gitProxy`** is not supported.
- **Issues** (the sidebar's ISSUES and the issue panel) work with github.com only in v0.1. GitHub Enterprise hosts are planned ([#117](https://github.com/kkdy21/overgrove/issues/117)). Fetching from a GitHub Enterprise server works like any other Git server.
- **Partial clones** (`--filter`) can be fetched only with Git 2.45.1 or later. Views that need objects not yet downloaded show an error instead of fetching them.

The reasons behind these rules are in the [security review](../design/security-review.md) (T5, T6, T11, T12).
