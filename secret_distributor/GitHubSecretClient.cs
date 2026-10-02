using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace SecretDistributor;

/// <summary>
/// Writes a value into a GitHub Actions secret — repository-level, or scoped
/// to a deployment environment.
///
/// GitHub never accepts a plaintext secret: the value must be sealed with
/// libsodium's crypto_box_seal against the repository's own public key. That
/// single requirement is why this function is .NET — Sodium.Core does it in
/// one call, whereas PowerShell has no libsodium binding and .NET's BCL has
/// no X25519, so the alternative was hand-rolling four primitives.
/// </summary>
public sealed class GitHubSecretClient
{
    // GitHub rejects other shapes server-side, but with an unhelpful error.
    private static readonly Regex RepoPattern =
        new(@"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", RegexOptions.Compiled);
    private static readonly Regex SecretNamePattern =
        new(@"^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.Compiled);

    private readonly HttpClient _http;
    private readonly ILogger _log;

    public GitHubSecretClient(HttpClient http, ILogger log)
    {
        _http = http;
        _log = log;
    }

    public static void Validate(string repository, string secretName)
    {
        if (!RepoPattern.IsMatch(repository))
            throw new ArgumentException($"Repository must be 'owner/repo'; got '{repository}'.");

        if (!SecretNamePattern.IsMatch(secretName))
            throw new ArgumentException(
                $"GitHub secret names must start with a letter or underscore and contain only " +
                $"letters, digits and underscores; got '{secretName}'.");
    }

    /// <summary>
    /// Creates or updates an Actions secret. With <paramref name="environment"/>
    /// null it is a repository secret; otherwise it is scoped to that
    /// environment. Returns the key id used, which callers record so a later run
    /// can tell whether GitHub still holds the version it was given (Actions
    /// secrets cannot be read back).
    /// </summary>
    public async Task<string> SetSecretAsync(
        string repository,
        string? environment,
        string secretName,
        string value,
        string token,
        CancellationToken ct = default)
    {
        Validate(repository, secretName);

        var scope = await ResolveSecretsPathAsync(repository, environment, token, ct);
        var where = environment is null ? repository : $"{repository} (environment '{environment}')";

        using var request = BuildRequest(HttpMethod.Get, $"{scope}/public-key", token);

        using var keyResponse = await _http.SendAsync(request, ct);
        if (!keyResponse.IsSuccessStatusCode)
        {
            // Deliberately does not include the response body: GitHub error
            // payloads can echo request context, and this text reaches logs.
            throw new InvalidOperationException(
                $"Could not read the public key for '{where}' (HTTP {(int)keyResponse.StatusCode}). " +
                $"Check the token grants Secrets read/write there" +
                (environment is null ? "." : " and that the environment exists."));
        }

        var keyJson = await keyResponse.Content.ReadAsStringAsync(ct);
        using var doc = JsonDocument.Parse(keyJson);
        var publicKeyB64 = doc.RootElement.GetProperty("key").GetString()
            ?? throw new InvalidOperationException("Public key response contained no 'key'.");
        var keyId = doc.RootElement.GetProperty("key_id").GetString()
            ?? throw new InvalidOperationException("Public key response contained no 'key_id'.");

        // crypto_box_seal: ephemeral keypair, nonce = Blake2b(epk || rpk),
        // output is epk || ciphertext. Sodium.Core handles all of it.
        var sealedBytes = Sodium.SealedPublicKeyBox.Create(
            Encoding.UTF8.GetBytes(value),
            Convert.FromBase64String(publicKeyB64));

        var payload = JsonSerializer.Serialize(new
        {
            encrypted_value = Convert.ToBase64String(sealedBytes),
            key_id = keyId
        });

        using var put = BuildRequest(HttpMethod.Put, $"{scope}/{secretName}", token);
        put.Content = new StringContent(payload, Encoding.UTF8, "application/json");

        using var putResponse = await _http.SendAsync(put, ct);
        if (!putResponse.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Failed to set secret '{secretName}' in '{where}' " +
                $"(HTTP {(int)putResponse.StatusCode}).");
        }

        _log.LogInformation("Set GitHub Actions secret {Secret} in {Where} (key id {KeyId}).",
            secretName, where, keyId);

        return keyId;
    }

    /// <summary>
    /// The URL prefix secrets live under. Environment secrets are addressed by
    /// the repository's numeric id, not its name, so that path costs one extra
    /// lookup.
    /// </summary>
    private async Task<string> ResolveSecretsPathAsync(
        string repository, string? environment, string token, CancellationToken ct)
    {
        if (environment is null)
            return $"https://api.github.com/repos/{repository}/actions/secrets";

        using var request = BuildRequest(HttpMethod.Get, $"https://api.github.com/repos/{repository}", token);
        using var response = await _http.SendAsync(request, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException(
                $"Could not look up repository '{repository}' (HTTP {(int)response.StatusCode}). " +
                $"Check it exists and the token can read it.");
        }

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var id = doc.RootElement.GetProperty("id").GetInt64();

        return $"https://api.github.com/repositories/{id}/environments/{Uri.EscapeDataString(environment)}/secrets";
    }

    private static HttpRequestMessage BuildRequest(HttpMethod method, string uri, string token)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("secret-distributor", "1.0"));
        return request;
    }
}
