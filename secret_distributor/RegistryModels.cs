using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace SecretDistributor;

/// <summary>
/// One Key Vault secret and where it is distributed. The document id IS the
/// Key Vault secret name, so an Event Grid subject resolves with a point read.
///
/// Holds metadata only. A secret VALUE never belongs in this document — it
/// stays in Key Vault and is referenced by name.
///
/// Edited by people through the registry API. Anything the system writes back
/// lives in <see cref="SecretState"/> instead, so the two writers never
/// overwrite each other's fields.
/// </summary>
public sealed class RegistryEntry
{
    private static readonly Regex IdPattern =
        new(@"^[0-9A-Za-z-]{1,127}$", RegexOptions.Compiled); // Key Vault's own secret-name rule

    public string Id { get; set; } = "";
    public string? DisplayName { get; set; }
    public string? Owner { get; set; }

    /// <summary>
    /// The Azure subscription and service principal this secret belongs to.
    /// Reference data only — nothing is pushed or acted on from these; they let
    /// a person or UI see which identity an entry is for.
    /// </summary>
    public string? SubscriptionId { get; set; }
    public string? ClientId { get; set; }

    /// <summary>Set false to pause distribution without deleting the entry.</summary>
    public bool Enabled { get; set; } = true;

    public List<DistributionTarget> Targets { get; set; } = new();

    /// <summary>Stamped by the server on every write; any client value is overwritten.</summary>
    public DateTime? UpdatedUtc { get; set; }

    /// <summary>The signed-in user who last wrote this entry. Server-set, like UpdatedUtc.</summary>
    public string? UpdatedBy { get; set; }

    /// <summary>Cosmos concurrency token. Send back as If-Match to update.</summary>
    [JsonPropertyName("_etag")]
    public string? ETag { get; set; }

    /// <summary>Returns every problem found, or an empty list when the entry is acceptable.</summary>
    public List<string> Validate()
    {
        var errors = new List<string>();

        if (!IdPattern.IsMatch(Id))
            errors.Add("id must be a Key Vault secret name: 1-127 characters of letters, digits and '-'.");

        if (SubscriptionId is not null && !Guid.TryParse(SubscriptionId, out _))
            errors.Add("subscriptionId must be a GUID.");
        if (ClientId is not null && !Guid.TryParse(ClientId, out _))
            errors.Add("clientId must be a GUID.");

        if (Targets.Count > 20)
            errors.Add("At most 20 targets per secret.");

        var duplicate = Targets.GroupBy(t => t.Key).FirstOrDefault(g => g.Count() > 1);
        if (duplicate is not null)
            errors.Add($"Duplicate target '{duplicate.Key}'.");

        for (var i = 0; i < Targets.Count; i++)
        {
            foreach (var problem in Targets[i].Validate())
                errors.Add($"targets[{i}]: {problem}");
        }

        return errors;
    }
}

public sealed class DistributionTarget
{
    /// <summary>A repository-level Actions secret.</summary>
    public const string GitHubActions = "github-actions";

    /// <summary>An Actions secret scoped to a deployment environment.</summary>
    public const string GitHubEnvironment = "github-environment";

    private static readonly Regex TokenSecretPattern =
        new(@"^[0-9A-Za-z-]{1,127}$", RegexOptions.Compiled);

    public string Type { get; set; } = GitHubActions;

    /// <summary>
    /// "owner/repo", or a bare "repo" when GITHUB_DEFAULT_ORG is set. Read
    /// <see cref="FullRepo"/> for the qualified form.
    /// </summary>
    public string Repo { get; set; } = "";

    /// <summary>Required for github-environment targets, rejected otherwise.</summary>
    public string? Environment { get; set; }

    /// <summary>Name of the Actions secret to write.</summary>
    public string SecretName { get; set; } = "";

    /// <summary>
    /// Key Vault secret holding the PAT for this target. Null falls back to the
    /// app-level default. Names a secret — never the token itself.
    /// </summary>
    public string? TokenSecret { get; set; }

    /// <summary>Repo qualified with the default org when it was given bare.</summary>
    [JsonIgnore]
    public string FullRepo
    {
        get
        {
            if (Repo.Contains('/')) return Repo;
            var org = System.Environment.GetEnvironmentVariable("GITHUB_DEFAULT_ORG");
            return string.IsNullOrWhiteSpace(org) ? Repo : $"{org.Trim()}/{Repo}";
        }
    }

    /// <summary>Identity of the destination, used to match a target to its recorded state.</summary>
    [JsonIgnore]
    public string Key => $"{FullRepo}|{Environment}|{SecretName}";

    public List<string> Validate()
    {
        var errors = new List<string>();

        if (Type != GitHubActions && Type != GitHubEnvironment)
            errors.Add($"type must be '{GitHubActions}' or '{GitHubEnvironment}'.");

        if (!Repo.Contains('/') && FullRepo == Repo)
            errors.Add($"repo '{Repo}' has no owner and GITHUB_DEFAULT_ORG is not set; use 'owner/repo'.");
        else
        {
            try
            {
                GitHubSecretClient.Validate(FullRepo, SecretName);
            }
            catch (ArgumentException ex)
            {
                errors.Add(ex.Message);
            }
        }

        if (Type == GitHubEnvironment)
        {
            if (string.IsNullOrWhiteSpace(Environment) || Environment.Length > 255 || Environment.Any(char.IsControl))
                errors.Add("environment is required for github-environment targets (1-255 characters, no control characters).");
        }
        else if (Environment is not null)
        {
            errors.Add($"environment is only valid on '{GitHubEnvironment}' targets.");
        }

        if (TokenSecret is not null && !TokenSecretPattern.IsMatch(TokenSecret))
            errors.Add("tokenSecret must be a Key Vault secret name.");

        return errors;
    }
}

/// <summary>
/// What the distributor last did for a secret. Written only by the function;
/// the API exposes it read-only. Actions secrets cannot be read back from
/// GitHub, so this is the only record of what GitHub was given.
/// </summary>
public sealed class SecretState
{
    public string Id { get; set; } = "";
    public List<TargetState> Targets { get; set; } = new();

    [JsonPropertyName("_etag")]
    public string? ETag { get; set; }
}

public sealed class TargetState
{
    /// <summary>Fully qualified "owner/repo", so it matches <see cref="DistributionTarget.Key"/>.</summary>
    public string Repo { get; set; } = "";
    public string? Environment { get; set; }
    public string SecretName { get; set; } = "";

    [JsonIgnore]
    public string Key => $"{Repo}|{Environment}|{SecretName}";

    public string? Version { get; set; }
    public DateTime? PushedUtc { get; set; }
    public string? KeyId { get; set; }
}
