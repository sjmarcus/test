using Azure;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;

namespace SecretDistributor;

/// <summary>What happened to one target on a push.</summary>
public sealed class TargetResult
{
    public string Repo { get; init; } = "";
    public string? Environment { get; init; }
    public string SecretName { get; init; } = "";

    /// <summary>"pushed", "failed" (will retry on an event) or "skipped" (permanent until fixed).</summary>
    public string Status { get; init; } = "";
    public string? Message { get; init; }
}

public sealed class PushResult
{
    public List<TargetResult> Targets { get; } = new();

    /// <summary>Failures worth retrying; the Event Grid path throws on these so the event is redelivered.</summary>
    public int Retryable { get; set; }
}

/// <summary>
/// Pushes a Key Vault secret's current value to GitHub Actions secrets and
/// records the result. Shared by the Event Grid function (a new version
/// arrived, push to every target) and the registry API (targets were added to
/// an existing secret, push to just those without waiting for the next
/// rotation).
/// </summary>
public sealed class SecretPusher
{
    private readonly ILogger<SecretPusher> _log;
    private readonly IHttpClientFactory _httpFactory;
    private readonly RegistryStore _registry;

    public SecretPusher(ILogger<SecretPusher> log, IHttpClientFactory httpFactory, RegistryStore registry)
    {
        _log = log;
        _httpFactory = httpFactory;
        _registry = registry;
    }

    public static string? VaultUri => Environment.GetEnvironmentVariable("KEY_VAULT_URI");

    public static SecretClient OpenVault(string vaultUri) => new(new Uri(vaultUri), new DefaultAzureCredential());

    /// <summary>
    /// Pushes <paramref name="secret"/> to <paramref name="targets"/>. Never
    /// throws for a per-target problem; each is reported in the result.
    /// <paramref name="entry"/> is null for legacy tag-driven secrets, whose
    /// state lives in tags rather than Cosmos.
    /// </summary>
    public async Task<PushResult> PushAsync(
        SecretClient client, KeyVaultSecret secret, RegistryEntry? entry,
        IReadOnlyList<DistributionTarget> targets, CancellationToken ct)
    {
        var secretName = secret.Name;
        var defaultTokenSecret = Environment.GetEnvironmentVariable("GITHUB_TOKEN_SECRET_NAME") ?? "github-pat";

        var github = new GitHubSecretClient(_httpFactory.CreateClient("github"), _log);
        var tokens = new Dictionary<string, string?>(); // one Key Vault read per distinct PAT
        var pushed = new List<TargetState>();
        var result = new PushResult();

        foreach (var target in targets)
        {
            TargetResult Outcome(string status, string? message = null) => new()
            {
                Repo = target.FullRepo, Environment = target.Environment, SecretName = target.SecretName,
                Status = status, Message = message,
            };

            // Registry entries are validated on write, but legacy tags never were.
            var problems = target.Validate();
            if (problems.Count > 0)
            {
                _log.LogError("Secret '{Secret}' has an invalid target ({Problems}). Not retrying it.",
                    secretName, string.Join("; ", problems));
                result.Targets.Add(Outcome("skipped", string.Join("; ", problems)));
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
            if (token is null)
            {
                // already logged; permanent until someone fixes the secret
                result.Targets.Add(Outcome("skipped", $"GitHub token in Key Vault secret '{tokenSecretName}' is unusable."));
                continue;
            }

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
                result.Targets.Add(Outcome("pushed"));
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
                result.Targets.Add(Outcome("failed", ex.Message));
                result.Retryable++;
            }
        }

        // Record what was distributed BEFORE surfacing failures, so targets that
        // succeeded are noted even when a sibling failed. Actions secrets cannot
        // be read back, so this is the only way to tell what GitHub holds.
        if (pushed.Count > 0)
            await RecordAsync(entry, secret, client, secretName, pushed, ct);

        return result;
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
}
