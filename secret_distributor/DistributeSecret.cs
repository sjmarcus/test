using System.Text.Json;
using Azure;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Azure.Cosmos;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace SecretDistributor;

/// <summary>
/// Distributes a Key Vault secret to its configured targets.
///
/// Triggered by Microsoft.KeyVault.SecretNewVersionCreated, so it reacts to
/// ANY new version — one this system's rotation wrote, or one a person or
/// another process created. That decoupling is the point: distribution does
/// not need to own the rotation to keep consumers current, and a failed push
/// can be replayed by re-firing the event without rotating again.
///
/// Where the targets come from, in order:
///   1. The registry (Cosmos) entry whose id is the secret name. Supports
///      several targets per secret (repository or environment scoped) and can
///      be paused with Enabled = false.
///   2. LEGACY tags on the secret itself, used only when the registry is not
///      configured or has no entry. Kept so nothing breaks before the tag
///      metadata has been imported (see scripts/Import-TagsToRegistry.ps1).
///         GITHUB-REPO          "owner/repo"
///         GITHUB-SECRET-NAME   the Actions secret to write
///         GITHUB-TOKEN-SECRET  optional, Key Vault secret holding the PAT
///
/// A secret with neither is not ours and is ignored.
/// </summary>
public class DistributeSecret
{
    private readonly ILogger<DistributeSecret> _log;
    private readonly IHttpClientFactory _httpFactory;
    private readonly RegistryStore _registry;

    public DistributeSecret(ILogger<DistributeSecret> log, IHttpClientFactory httpFactory, RegistryStore registry)
    {
        _log = log;
        _httpFactory = httpFactory;
        _registry = registry;
    }

    [Function(nameof(DistributeSecret))]
    public async Task Run([EventGridTrigger] CloudEvent cloudEvent, CancellationToken ct)
    {
        var secretName = cloudEvent.Subject;
        _log.LogInformation("Event {Type} for secret '{Secret}'.", cloudEvent.EventType, secretName);

        if (string.IsNullOrWhiteSpace(secretName))
        {
            _log.LogError("Event carried no subject; nothing to distribute. Not retrying.");
            return;
        }

        var vaultUri = Environment.GetEnvironmentVariable("KEY_VAULT_URI");
        if (string.IsNullOrWhiteSpace(vaultUri))
        {
            // Deterministic: retrying will not conjure an app setting.
            _log.LogError("KEY_VAULT_URI is not set. Not retrying.");
            return;
        }

        var client = new SecretClient(new Uri(vaultUri), new DefaultAzureCredential());

        KeyVaultSecret secret;
        try
        {
            secret = await client.GetSecretAsync(secretName, cancellationToken: ct);
        }
        catch (RequestFailedException ex) when (ex.Status is 403 or 404)
        {
            // Permission or existence problems will fail identically on every
            // retry, and Event Grid would try 30 times over 24h.
            _log.LogError(ex, "Cannot read secret '{Secret}' (HTTP {Status}). Not retrying.", secretName, ex.Status);
            return;
        }

        var tags = secret.Properties.Tags;
        var defaultTokenSecret = Environment.GetEnvironmentVariable("GITHUB_TOKEN_SECRET_NAME") ?? "github-pat";

        // Cosmos failures are deliberately NOT caught: throttling, a transient
        // 5xx, or RBAC that has not propagated yet all clear on a later attempt,
        // and swallowing them would drop the only event this version produces.
        RegistryEntry? entry = _registry.IsConfigured
            ? await _registry.GetEntryAsync(secretName, ct)
            : null;

        List<DistributionTarget> targets;
        if (entry is not null)
        {
            if (!entry.Enabled)
            {
                _log.LogInformation("Registry entry '{Secret}' is disabled; nothing to distribute.", secretName);
                return;
            }
            targets = entry.Targets;
        }
        else if (TryGetTag(tags, "GITHUB-REPO", out var repository) &&
                 TryGetTag(tags, "GITHUB-SECRET-NAME", out var targetName))
        {
            _log.LogWarning(
                "Secret '{Secret}' has no registry entry; using legacy GITHUB-* tags. Import them into the registry.",
                secretName);
            targets = new List<DistributionTarget>
            {
                new()
                {
                    Repo = repository!,
                    SecretName = targetName!,
                    TokenSecret = TryGetTag(tags, "GITHUB-TOKEN-SECRET", out var taggedToken) ? taggedToken : null,
                },
            };
        }
        else
        {
            // Not an error: most secrets in the vault are not distributed.
            _log.LogInformation(
                "Secret '{Secret}' is not in the registry and has no GITHUB-* tags; nothing to distribute.",
                secretName);
            return;
        }

        if (targets.Count == 0)
        {
            _log.LogInformation("Registry entry '{Secret}' has no targets; nothing to distribute.", secretName);
            return;
        }

        var github = new GitHubSecretClient(_httpFactory.CreateClient("github"), _log);
        var tokens = new Dictionary<string, string?>(); // one Key Vault read per distinct PAT
        var pushed = new List<TargetState>();
        var retryable = 0;

        foreach (var target in targets)
        {
            // Registry entries are validated on write, but legacy tags never were.
            var problems = target.Validate();
            if (problems.Count > 0)
            {
                _log.LogError("Secret '{Secret}' has an invalid target ({Problems}). Not retrying it.",
                    secretName, string.Join("; ", problems));
                continue;
            }

            // The token is named by the target so different teams' repositories
            // can use separately scoped PATs. It names a Key Vault SECRET, never
            // the token itself — a token in a tag or document would be readable
            // by anyone who can list secret properties.
            var tokenSecretName = target.TokenSecret ?? defaultTokenSecret;
            if (!tokens.TryGetValue(tokenSecretName, out var token))
            {
                token = await ReadTokenAsync(client, tokenSecretName, ct);
                tokens[tokenSecretName] = token;
            }
            if (token is null) continue; // already logged; permanent until someone fixes the secret

            try
            {
                var keyId = await github.SetSecretAsync(
                    target.FullRepo, target.Environment, target.SecretName, secret.Value, token, ct);
                pushed.Add(new TargetState
                {
                    Repo = target.FullRepo,
                    Environment = target.Environment,
                    SecretName = target.SecretName,
                    Version = secret.Properties.Version,
                    PushedUtc = DateTime.UtcNow,
                    KeyId = keyId,
                });
                _log.LogInformation(
                    "Distributed '{Secret}' to {Repo} (environment: {Environment}) as '{Target}' using token from '{TokenSecret}'.",
                    secretName, target.FullRepo, target.Environment ?? "none", target.SecretName, tokenSecretName);
            }
            catch (InvalidOperationException ex)
            {
                // Transient (5xx, network) vs permanent (401/403/404) is hard to
                // separate reliably from the message, so let Event Grid retry —
                // a repeated push of the same value is harmless, since setting
                // an Actions secret is idempotent.
                _log.LogError(ex, "Distribution of '{Secret}' to {Repo} failed; allowing retry.", secretName, target.FullRepo);
                retryable++;
            }
        }

        // Record what was distributed BEFORE surfacing failures, so targets that
        // succeeded are noted even when a sibling failed. Actions secrets cannot
        // be read back, so this is the only way to tell what GitHub holds.
        if (pushed.Count > 0)
            await RecordAsync(entry, secret, client, secretName, pushed, ct);

        if (retryable > 0)
            throw new InvalidOperationException(
                $"{retryable} of {targets.Count} target(s) for '{secretName}' failed; retrying the event.");
    }

    /// <summary>
    /// Registry-backed secrets record state in Cosmos; legacy tag-driven ones
    /// keep using tags. Failing to record never fails the run: the push already
    /// happened, and retrying would re-push a value GitHub already has.
    /// </summary>
    private async Task RecordAsync(
        RegistryEntry? entry, KeyVaultSecret secret, SecretClient client,
        string secretName, List<TargetState> pushed, CancellationToken ct)
    {
        try
        {
            if (entry is not null)
            {
                var state = await _registry.GetStateAsync(secretName, ct) ?? new SecretState { Id = secretName };

                // Merge over what is already recorded, then drop targets that
                // are no longer in the entry so stale rows do not linger.
                foreach (var p in pushed)
                {
                    state.Targets.RemoveAll(t => t.Key == p.Key);
                    state.Targets.Add(p);
                }
                var current = entry.Targets.Select(x => x.Key).ToHashSet();
                state.Targets.RemoveAll(t => !current.Contains(t.Key));

                await _registry.UpsertStateAsync(state, ct);
            }
            else
            {
                var p = pushed[0]; // legacy tags carry exactly one target
                secret.Properties.Tags["LAST-PUSHED-VERSION"] = p.Version ?? "";
                secret.Properties.Tags["LAST-PUSHED-UTC"] = p.PushedUtc!.Value.ToString("o");
                secret.Properties.Tags["LAST-PUSHED-KEY-ID"] = p.KeyId ?? "";
                await client.UpdateSecretPropertiesAsync(secret.Properties, ct);
            }
        }
        catch (Exception ex) when (ex is RequestFailedException or CosmosException)
        {
            _log.LogWarning(ex, "Pushed '{Secret}' but could not record the result.", secretName);
        }
    }

    /// <summary>Returns the trimmed PAT, or null (after logging why) when it is unusable.</summary>
    private async Task<string?> ReadTokenAsync(SecretClient client, string tokenSecretName, CancellationToken ct)
    {
        string token;
        try
        {
            token = (await client.GetSecretAsync(tokenSecretName, cancellationToken: ct)).Value.Value;
        }
        catch (RequestFailedException ex)
        {
            _log.LogError(ex, "Could not read the GitHub token from secret '{Token}' (HTTP {Status}).",
                tokenSecretName, ex.Status);
            return null;
        }

        // A PAT pasted from a multi-line source carries a trailing newline, and
        // .NET refuses newlines in header values — which surfaces as an opaque
        // "New-line characters are not allowed in header values" far from the
        // cause. Normalise here and fail with something that names the problem.
        token = token?.Trim() ?? string.Empty;
        if (string.IsNullOrEmpty(token))
        {
            _log.LogError("GitHub token in secret '{Token}' is empty after trimming. Not retrying.", tokenSecretName);
            return null;
        }
        if (token.Any(c => char.IsControl(c)))
        {
            _log.LogError(
                "GitHub token in secret '{Token}' contains control characters and cannot be used as a header value. " +
                "Re-store it as a single line. Not retrying.", tokenSecretName);
            return null;
        }
        return token;
    }

    private static bool TryGetTag(IDictionary<string, string> tags, string key, out string? value)
    {
        value = null;
        if (tags is null) return false;

        // Tag keys are case-sensitive on read but operators are not.
        foreach (var kvp in tags)
        {
            if (string.Equals(kvp.Key, key, StringComparison.OrdinalIgnoreCase))
            {
                value = kvp.Value;
                return !string.IsNullOrWhiteSpace(value);
            }
        }
        return false;
    }
}

/// <summary>
/// Minimal shape of the Event Grid payload this function needs.
/// </summary>
public sealed class CloudEvent
{
    public string? Id { get; set; }
    public string? EventType { get; set; }
    public string? Subject { get; set; }
    public JsonElement Data { get; set; }
}
