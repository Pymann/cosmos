# 115 — Secrets for steps

Status: decided 2026-11-27.  The model is the Jenkins one: credentials are declared on the server,
a stage binds them by name, the agent hands them to the step as environment variables or files,
and the log masks them.  Watching **every** stream a step writes to (files, sockets, other file
descriptors) is a later slice on the aiml side (§115.9).

## 115.1 Why

A step that checks out a private repository, publishes a package or signs an artefact needs a
credential.  Until now the only way was to put it on the agent host by hand (`/gitcred`,
doc/spec/114 §114.5), which binds a secret to a machine instead of a stage, and every step on
that machine sees it.

## 115.2 What is declared — the kinds

Secrets stay where they are: under `config.secrets` (doc/spec/111 §111.1).  The value comes from
`file:` or `env:` on the **server**, never from the declaration (F100-10).  New is `kind:` and the
non-secret parts a kind needs.

```yaml
- config:
    secrets:
      - secret: { name: gh_token, env: COSMOS_GITHUB_TOKEN }                  # kind: token (default)
      - secret: { name: deploy,   kind: user_password, user: deployer, file: secrets/deploy.pw }
      - secret: { name: signing,  kind: file,          file: secrets/sign.p12 }
      - secret: { name: git_ssh,  kind: ssh_key,       file: secrets/id_ed25519,
                  user: git, passphrase: git_ssh_pp, known_hosts: secrets/known_hosts }
      - secret: { name: client,   kind: tls_client,    file: secrets/client.key,
                  cert: secrets/client.pem, ca: secrets/ca.pem }
      - secret: { name: git_ssh_pp, env: COSMOS_GIT_SSH_PASSPHRASE }
```

| kind | secret part (`file:`/`env:`) | other fields | masked |
|---|---|---|---|
| `token` | the token | — | the value |
| `user_password` | the password | `user:` | the password, `base64(user:password)` |
| `file` | the file content (text; a binary file is declared base64 and decoded in the step) | — | each line of 16 bytes or more |
| `ssh_key` | the private key | `user:`, `passphrase:` (a secret **name**), `known_hosts:` (a path) | each key line of 16 bytes or more, the passphrase |
| `tls_client` | the private key | `cert:`, `ca:` (paths) | each key line of 16 bytes or more |

- **F115-1** `kind:` defaults to `token`.  An existing declaration means what it meant.
- **F115-2** Only the secret part is secret.  `user:`, `cert:`, `ca:` and `known_hosts:` are
  configuration, may appear in a plan and are not masked; a username in a log is not a leak, and
  masking it would hide every path that contains it.
- **F115-3** `passphrase:` names **another** secret.  A passphrase is a secret, so it follows
  F100-10 like every other value.  A name that is not declared is a plan error, as for
  `git.token` (F114-1).
- **F115-4** The kinds live in their own KV `casc_secret_kinds`, keyed by name, beside
  `casc_config` and never as new fields of `CascSecret` (doc/spec/108 F108-2): a field on the
  stored model makes the stored configuration unreadable.
- **F115-5** Paths are relative to the declaration, as for `file:` (doc/spec/111 §111.1).

## 115.3 What a pipeline says — `secrets:`

```yaml
- pipeline:
    name: publish
    secrets:
      - { name: gh_token, env: GH_TOKEN }
    steps:
      - stage:
          name: upload
          secrets:
            - { name: deploy, env: DEPLOY }
          run: 'curl -u "$DEPLOY_USER:$DEPLOY_PASSWORD" -T out.tgz https://repo.example/'
```

aiml spec/62 §18.6 defines the keyword; the reader `stg.secrets` gives `name:ENV,…`.

- **F115-6** A pipeline names a secret by its **name**, never by its value, and the name binds
  to an **environment name**.  The same rule as `shares:` and `image:`: the pipeline is user
  input, the server knows what the name stands for.
- **F115-7** Pipeline and stage `secrets:` add up; with the same `env:` the stage wins
  (aiml F62-166).  A stage that needs a credential does not make every other stage see it.
- **F115-8** A stage with secrets is **opaque** (aiml F62-167).  Its output depends on
  something that is not key material and must not be: a key that held the value would put it into
  every store the key travels to, and a key without it would hand a layer built with one
  credential to a run that has another.
- **F115-9** Who may run a pipeline may use every secret it names.  There is no per-secret
  grant in this slice, as in Jenkins without folder-scoped credentials.  Forks are not treated
  apart: a repository whose secrets must not reach a fork's pipeline turns forking off
  (decided 2026-11-27).

## 115.4 How it reaches the step

The server resolves the names when it **hands out** the stage (`claim_step`), not when the run is
submitted: a secret that was rotated between submit and start must be the new one, and nothing
with a value is stored in the run.

```
submit ──► stage_secrets["<run>-<lane>-<nr>"] = "deploy:DEPLOY,gh_token:GH_TOKEN"   (names only)
claim  ──► StepAssignment.secrets = [ { env, kind, value, user, … } ]               (values, in memory)
agent  ──► <step>.secrets/ (0700)  env (0400), files (0400), masks (0400)
step   ──► `. <step>.secrets/env` before the command; the files by path
end    ──► <step>.secrets/ removed
```

What the step sees, per kind:

| kind | variables |
|---|---|
| `token` | `ENV` = the value |
| `user_password` | `ENV_USER`, `ENV_PASSWORD` |
| `file` | `ENV` = path of the file |
| `ssh_key` | `ENV` = path of the key; `ENV_USER`, `ENV_PASSPHRASE`, `ENV_KNOWN_HOSTS` (a path) when declared |
| `tls_client` | `ENV_KEY`, `ENV_CERT`, `ENV_CA` (paths; `_CA` when declared) |

- **F115-10** **Never in an argument list.**  `/proc/<pid>/cmdline` is readable by every user of
  the host; bwrap's `--setenv` puts its value exactly there.  The values are written to an `env`
  file that the step's shell sources before the command; the command line names only the file.
- **F115-11** The files lie in `<step>.secrets/`, **beside** the step directory and not in it.  A
  step that packs its own directory (`tar czf out.tgz .`) must not pack its credentials.  The
  directory is `0700`, each file `0400`, and it is removed when the step ends — before the
  report, so a report that does not get through does not keep the secret on disk.  In a container
  the agent's work root is the container's; on a bare node bwrap binds the directory read-only.
- **F115-12** A secret that cannot be resolved — not declared, the file missing, the variable
  empty — fails the stage **at once** with exit 125 and a message that names the secret, never
  its value.  Waiting for a credential that will not come is a lease that runs out for nothing.
- **F115-13** A value shorter than **4 bytes** is refused the same way.  It cannot be masked
  without masking ordinary text (`abc` is in every third line), and an unmaskable secret is one
  that leaks.
- **F115-14** The assignment travels on the agent's own connection, the same one that carries
  its token.  Over a network that is not trusted, that connection must be TLS (doc/spec/112).

## 115.5 Masking

```
step ──► out / err (files on the agent) ──► OutPump: mask, hold back ──► command_output ──► server: mask ──► log
```

- **F115-15** The agent masks every chunk **before it leaves the host**.  Each masked value is
  replaced by `****`, longest value first, so a value that contains another one is not half
  masked.
- **F115-16** A chunk ends where a value might begin.  The pump reads a window, sends all but the
  last `longest − 1` bytes, and moves the cut back to the start of any value that crosses it; the
  rest comes with the next chunk.  When the step has ended (its status file is there), the
  remainder is sent.  Without this a value split over two chunks is in the log in two halves,
  and neither half is masked.
- **F115-17** The **server masks again** when it appends a chunk to the run log, with the values
  of that stage held in memory from `claim_step` to the report.  It is the second net, for an
  agent that is older than the server or has lost its masks; it is not the first, because after
  a server restart it has none.
- **F115-18** What is masked: the value; `base64` of the value; for `user_password` also
  `base64(user:password)` (the HTTP Basic header); for multi-line values each line of 16 bytes or
  more (the body lines of a PEM key) and its `base64` is not attempted.  Short lines of a key file
  (`-----BEGIN …`) are not secret.
- **F115-19** The agent's own copy of the output (`out`, `err` in the step directory) is not
  masked: it is the raw record on the host where the step ran, readable by the agent user only.
  The report note and the "output cut" note go through the same masker.
- **F115-20** An agent that restarts while a stage with secrets runs reads its masks back from
  `<step>.secrets/masks` (base64, one per line, `0400`) and keeps masking.  If the file is gone,
  it does not ship the rest of the output and says so in one line.

**Cost.**  Per chunk (at most 64 KiB, doc/spec/103 §103.4e) one search per masked value.  With
the handful of secrets a stage binds that is microseconds against the milliseconds a chunk spends
on the network.  A multi-pattern search (Aho–Corasick) in aiml becomes worth it only with dozens
of values per stage; it is noted in §115.9 and not built now.

**Limit.**  Masking catches accidents — an `echo`, `set -x`, a tool that prints its
configuration.  It does not stop a step that wants to leak a value: it can send it over the
network, reverse it, or print it one character per line.  That is the same in Jenkins, and the
reason for F115-9: who may run the pipeline is trusted with what it names.

## 115.6 Plan and apply

- **F115-21** `config_plan` lists a changed kind or a changed non-secret field of a secret as a
  change (`secret.deploy.kind`, `secret.deploy.user`).  Values never appear.
- **F115-22** An unknown `kind:` and a field the kind does not take (`cert:` on a `token`) are
  plan errors; `secrets:` entries had no unknown-key leniency before and do not get one now
  (doc/spec/111 §111.1).
- **F115-23** A run whose stage names a secret the configuration does not declare is **not**
  rejected at submit: the configuration can be applied between submit and claim.  The stage fails
  at claim (F115-12).

## 115.7 Where it lives in the code

| What | Where |
|---|---|
| kinds: model, read, plan, apply | `sources/models/secret_kind.aiml`, `sources/server/secret_kinds.aiml`, `casc_reader.aiml` |
| bindings per stage (names only) | `sources/server/stage_secrets.aiml` (KV `stage_secrets`) |
| resolve at claim | `StageSecretStore.bind` from `claim_step` |
| wire | `StepAssignment.secrets`, `secret_error`; model `StepSecret` |
| masking | `sources/shared/secret_mask.aiml` (`cosmos.secrets.SecretMask`), used by `OutPump` and `RunStore` |
| agent: files, env, cleanup | `sources/agent/agent_secrets.aiml`, called from `StepWorker` |

## 115.8 Acceptance

- **A115-1** A stage binding a `token` sees it as `$ENV`; `echo $ENV` shows `****` in the run log
  (end to end), and the server masks a stage's chunks on its own (unit test, F115-17).
- **A115-2** A value printed across a chunk boundary is masked (unit test of the pump).
- **A115-3** `user_password` gives `_USER` and `_PASSWORD`; `base64(user:password)` is masked.
- **A115-4** `file` gives a path to a `0400` file outside the step directory; after the step the
  directory is gone.
- **A115-5** A stage naming an undeclared secret ends with 125 and the name in the message.
- **A115-6** `ps -ef` during the step shows no value.
- **A115-7** A stage with secrets is not reused by the step cache, even when the pipeline says
  `cache: pure`.

Verified by `test/test_step_secrets.aiml` (masker, declaration, submit and claim, server net, agent
files) and the secret probe of `run_e2e_pipeline.sh` (a real agent; A115-1..6).

## 115.9 Later

- **Every stream (aiml side).**  Masking now covers what the agent ships: stdout and stderr.  A
  step can still write a value into a file of its layer, a share or an artefact.  The plan is to
  watch at the source, in the aiml runtime that starts the step's process: every file descriptor
  the process writes to goes through the masker, and a layer or artefact that leaves the host is
  scanned in the same pass that hashes it (a hit stops the export instead of masking it).  This
  needs aiml changes and is a later item on the roadmap.
- A multi-pattern search builtin in aiml, when stages bind many secrets.
- Per-secret grants (which pipelines may name which secret), if one cosmos ever serves
  projects that must not share credentials.
- Short-lived credentials minted per run, where the service can (kontor tokens).
