GitHubSecretClient.cs
The GitHub-facing half. One public method, SetRepositorySecretAsync, doing three things in sequence:

1. Fetch the repo's public key. GET /repos/{owner}/{repo}/actions/secrets/public-key returns a base64 key and a key_id. Every repo has its own.

2. Seal the value against it. Sodium.SealedPublicKeyBox.Create(...) — libsodium's crypto_box_seal. It generates a throwaway keypair, derives a nonce from both public keys, encrypts, and returns ephemeral_key || ciphertext. Only the repo's private key can open it, and GitHub holds that. This one call is the entire reason the function is .NET.

3. PUT the sealed value with the key_id, so GitHub knows which key it was sealed against.

It returns the key_id, which the caller records — Actions secrets can't be read back, so that's part of how you tell what GitHub was given.

A few deliberate details: input validation on the repo and secret name happens before any network call, because GitHub's own errors for bad shapes are unhelpful. Error messages carry the status code but never the response body — GitHub error payloads can echo request context, and that text goes to logs.

DistributeSecret.cs
The orchestration half, triggered by Event Grid on SecretNewVersionCreated. It's a sequence of guards, each returning early rather than throwing:

Validate the event — right type, has a subject, KEY_VAULT_URI is set.

Read the secret via managed identity. A 403 or 404 returns without throwing, deliberately: those fail identically on every retry, and throwing would burn 30 Event Grid attempts over 24 hours.

Check the tags. No GITHUB-REPO / GITHUB-SECRET-NAME means the secret isn't ours — logged as information, not an error. Most secrets in the vault aren't distributed.

Read the PAT from a separate Key Vault secret, so it can be rotated independently and never appears in tags or config.

Push, then record LAST-PUSHED-VERSION, LAST-PUSHED-UTC, LAST-PUSHED-KEY-ID.

Two decisions worth knowing
Push failures rethrow; tag-write failures don't. A failed push should retry — setting an Actions secret is idempotent, so a repeat is harmless. But if the push succeeded and only the bookkeeping failed, rethrowing would re-push a value GitHub already has. So that case logs a warning and moves on.

Permanent failures are swallowed, transient ones rethrow. Event Grid's retry budget is only useful for things that might succeed later.

One gap the last few hours exposed: there's no validation on the PAT itself. A trailing newline produced an opaque .NET header exception rather than a clear message. A .Trim() and an explicit check would fix that — still worth doing.