using System.Text.Json;
using Azure;
using Azure.Security.KeyVault.Secrets;
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
/// Targets added to an existing entry are pushed straight away by the registry
/// API (see <see cref="RegistryApi"/>), so they do not wait for the next version.
/// Both paths push through <see cref="SecretPusher"/>.
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
    private readonly RegistryStore _registry;
    private readonly SecretPusher _pusher;

    public DistributeSecret(ILogger<DistributeSecret> log, RegistryStore registry, SecretPusher pusher)
    {
        _log = log;
        _registry = registry;
        _pusher = pusher;
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

        var vaultUri = SecretPusher.VaultUri;
        if (string.IsNullOrWhiteSpace(vaultUri))
        {
            // Deterministic: retrying will not conjure an app setting.
            _log.LogError("KEY_VAULT_URI is not set. Not retrying.");
            return;
        }

        var client = SecretPusher.OpenVault(vaultUri);

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

        var result = await _pusher.PushAsync(client, secret, entry, targets, ct);

        if (result.Retryable > 0)
            throw new InvalidOperationException(
                $"{result.Retryable} of {targets.Count} target(s) for '{secretName}' failed; retrying the event.");
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
